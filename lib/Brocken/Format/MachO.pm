use v5.40;
use feature 'class';
no warnings 'experimental::class';

class Brocken::Format::MachO : isa(Brocken::Format) {

    method _setup_layout( $l, $t, $d, $a, $o, $dbg = 0 ) {
        $l->add_section( '.text', $t, 5 );
        $l->add_section( '.data', $d, 3 );
        if ( $dbg >= 1 ) {
            $l->add_section( '.debug_line',     4096, 0 );
            $l->add_section( '.debug_info',     8192, 0 );
            $l->add_section( '.debug_abbrev',   4096, 0 );
            $l->add_section( '.debug_frame',    8192, 0 );
            $l->add_section( '.debug_aranges',  4096, 0 );
            $l->add_section( '.debug_pubnames', 4096, 0 );
        }
    }
    method image_base () { return 0x100000000; }

    method write_bin( $f, $text, $data, $arch, $os ) {
        my $l           = $self->layout;
        my $base        = $self->image_base;
        my $page_size   = 0x4000;
        my $cputype     = ( $arch eq 'arm64' ) ? 0x0100000c : 0x01000007;
        my $cpusubtype  = ( $arch eq 'arm64' ) ? 0          : 3;
        my @debug_sects = grep { $_->{name} =~ /^\.debug/ } $l->sections;
        my $ncmds       = 4 + ( @debug_sects ? 1 : 0 );
        my $sizeofcmds  = 72 + 152 + 152 + 24;
        $sizeofcmds += 72 + 80 * scalar(@debug_sects) if @debug_sects;
        open my $fh, '>', $f or die $!;
        binmode $fh;
        print $fh pack(
            'L<L<L<L<L<L<L<L<', 0xfeedfacf,               # MH_MAGIC_64
            $cputype,           $cpusubtype, 2,           # MH_EXECUTE
            $ncmds,             $sizeofcmds, 0x200085,    # flags: NOUNDEFS | PIE | TWOLEVEL
            0
        );

        # LC_SEGMENT_64 __PAGEZERO
        print $fh pack(
            'L<L< a16 Q<Q< Q<Q< L<L<L<L<', 0x19, 72, "__PAGEZERO", 0, $base,    # vmaddr, vmsize
            0, 0,                                                               # fileoff, filesize
            0, 0,                                                               # maxprot, initprot
            0, 0                                                                # nsects, flags
        );

        # LC_SEGMENT_64 __TEXT
        my $t_sec          = $l->get('.text');
        my $t_size_aligned = ( $t_sec->{size} + $page_size - 1 ) & ~( $page_size - 1 );
        print $fh pack(
            'L<L< a16 Q<Q< Q<Q< L<L<L<L<', 0x19, 152, "__TEXT", $base, $t_sec->{rva} + $t_size_aligned, 0, $t_sec->{off} + $t_size_aligned, 5,
            5,                                                                  # maxprot, initprot (RX)
            1, 0                                                                # nsects
        );
        print $fh pack(
            'a16 a16 Q<Q< L<L< L<L<L< L<L< L<', "__text", "__TEXT", $base + $t_sec->{rva}, $t_sec->{size}, $t_sec->{off}, 4,    # offset, align
            0, 0, 0x80000400,    # reloff, nreloc, flags
            0, 0, 0
        );

        # LC_SEGMENT_64 __DATA
        my $d_sec          = $l->get('.data');
        my $d_size_aligned = ( $d_sec->{size} + $page_size - 1 ) & ~( $page_size - 1 );
        print $fh pack(
            'L<L< a16 Q<Q< Q<Q< L<L<L<L<', 0x19, 152, "__DATA", $base + $d_sec->{rva}, $d_size_aligned, $d_sec->{off}, $d_size_aligned, 3,
            3,                   # maxprot, initprot (RW)
            1, 0
        );
        print $fh
            pack( 'a16 a16 Q<Q< L<L< L<L<L< L<L< L<', "__data", "__DATA", $base + $d_sec->{rva}, $d_sec->{size}, $d_sec->{off}, 3, 0, 0, 0, 0, 0, 0 );

        # LC_SEGMENT_64 __DWARF
        if (@debug_sects) {
            my $cmdsize      = 72 + 80 * scalar(@debug_sects);
            my $dw_start_rva = $debug_sects[0]->{rva};
            my $dw_start_off = $debug_sects[0]->{off};
            my $dw_size      = 0;
            for (@debug_sects) { $dw_size += $_->{size}; }
            my $dw_size_aligned = ( $dw_size + $page_size - 1 ) & ~( $page_size - 1 );
            print $fh pack(
                'L<L< a16 Q<Q< Q<Q< L<L<L<L<', 0x19, $cmdsize, "__DWARF", $base + $dw_start_rva, $dw_size_aligned, $dw_start_off, $dw_size_aligned,
                0,                             0,    # maxprot, initprot (none)
                scalar(@debug_sects),          0
            );
            for my $s (@debug_sects) {
                ( my $macho_name = $s->{name} ) =~ s/^\./__/;
                print $fh
                    pack( 'a16 a16 Q<Q< L<L< L<L<L< L<L< L<', $macho_name, "__DWARF", $base + $s->{rva}, $s->{size}, $s->{off}, 0, 0, 0, 0, 0, 0, 0 );
            }
        }

        # LC_MAIN
        if ($self->type ne 'shared') {
            print $fh pack(
                'L<L< Q<Q< Q<', 0x80000028, 24, $t_sec->{off},    # entryoff
                0, 0                                              # stacksize
            );
        }

        # Pad to text section start
        print $fh ( "\0" x ( $t_sec->{off} - tell($fh) ) );

        # Write __TEXT
        print $fh $text . ( "\0" x ( $t_size_aligned - length($text) ) );

        # Write __DATA
        my $d_payload = $data // '';
        print $fh $d_payload . ( "\0" x ( $d_sec->{off} + $d_size_aligned - tell($fh) ) );

        # Write __DWARF
        if (@debug_sects) {
            for my $s (@debug_sects) {
                print $fh ( "\0" x ( $s->{off} - tell($fh) ) );
                my $dw_payload = $self->debug_section( $s->{name} ) || '';
                print $fh $dw_payload;
            }
        }
        close $fh;
        chmod 0755, $f;
        return $f;
    }
}
1;

            }
        }
        close $fh;
        chmod 0755, $f;
        return $f;
    }
}
1;
