--- START OF FILE MachO . pm-- - use v5.40;
use feature 'class';
no warnings 'experimental::class';

class Brocken::Format::MachO : isa(Brocken::Format) {

    method _setup_layout( $l, $t, $d, $a, $o, $dbg = 0 ) {
        $l->add_section( '.text', $t, 5 );
        $l->add_section( '.data', $d, 3 );
        if ( $self->type eq 'shared' ) {
            $l->add_section( '.linkedit', 4096, 1 );
        }
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
        my $cputype     = ( $arch eq 'arm64' )        ? 0x0100000c : 0x01000007;
        my $cpusubtype  = ( $arch eq 'arm64' )        ? 0          : 3;
        my $filetype    = ( $self->type eq 'shared' ) ? 6          : 2;            # MH_DYLIB = 6, MH_EXECUTE = 2
        my @debug_sects = grep { $_->{name} =~ /^\.debug/ } $l->sections;
        my ( $trie, $symtab, $strtab, $lc_id_dylib ) = ( '', '', '', '' );
        my ( $num_syms, $le_off, $trie_size, $symtab_size, $strtab_size ) = ( 0, 0, 0, 0, 0 );

        if ( $self->type eq 'shared' ) {
            require File::Basename;
            my $dylib_name     = File::Basename::basename($f);
            my $dylib_name_pad = $dylib_name . "\0";
            while ( length($dylib_name_pad) % 8 != 0 ) { $dylib_name_pad .= "\0"; }
            $lc_id_dylib = pack( 'L<L< L<L<L<L<', 0xD, 24 + length($dylib_name_pad), 24, 1, 1, 1 ) . $dylib_name_pad;
            my $_uleb = sub {
                my $v   = shift;
                my $out = '';
                do {
                    my $byte = $v & 0x7F;
                    $v >>= 7;
                    $byte |= 0x80 if $v;
                    $out .= pack( 'C', $byte );
                } while ($v);
                return $out;
            };
            my @exports = @{ $self->exported_funcs // [] };
            my %export_rvas;
            for my $name (@exports) {
                $export_rvas{"_$name"} = $l->get('.text')->{rva} + ( $self->labels->{"E_$name"} // 0 );
            }
            my @syms = sort keys %export_rvas;
            $num_syms = scalar @syms;
            $strtab   = "\0";
            my %strx;
            for my $sym (@syms) {
                $strx{$sym} = length($strtab);
                $strtab .= $sym . "\0";
            }
            while ( length($strtab) % 8 != 0 ) { $strtab .= "\0"; }
            for my $sym (@syms) {
                $symtab .= pack( 'L< C C S< Q<', $strx{$sym}, 0x0f, 1, 0, $base + $export_rvas{$sym} );
            }
            if ( $num_syms > 0 ) {
                my @nodes;
                for my $sym (@syms) {
                    my $rva        = $export_rvas{$sym};
                    my $flags_u    = $_uleb->(0);
                    my $rva_u      = $_uleb->($rva);
                    my $term_data  = $flags_u . $rva_u;
                    my $node_bytes = $_uleb->( length($term_data) ) . $term_data . pack( 'C', 0 );
                    push @nodes, { sym => $sym, bytes => $node_bytes };
                }
                my %node_offsets;
                for ( 1 .. 3 ) {
                    my $root = pack( 'C', 0 ) . pack( 'C', $num_syms );
                    for my $n (@nodes) { $root .= $n->{sym} . "\0" . $_uleb->( $node_offsets{ $n->{sym} } // 1024 ); }
                    my $offset = length($root);
                    for my $n (@nodes) {
                        $node_offsets{ $n->{sym} } = $offset;
                        $offset += length( $n->{bytes} );
                    }
                }
                $trie = pack( 'C', 0 ) . pack( 'C', $num_syms );
                for my $n (@nodes) { $trie .= $n->{sym} . "\0" . $_uleb->( $node_offsets{ $n->{sym} } ); }
                for my $n (@nodes) { $trie .= $n->{bytes}; }
                while ( length($trie) % 8 != 0 ) { $trie .= "\0"; }
            }
            $trie_size                   = length($trie);
            $symtab_size                 = length($symtab);
            $strtab_size                 = length($strtab);
            $l->get('.linkedit')->{size} = $trie_size + $symtab_size + $strtab_size;
            $l->calculate($page_size);
            $le_off = $l->get('.linkedit')->{off};
        }
        my $ncmds = ( $self->type eq 'shared' ) ? 7 : 3;
        $ncmds += @debug_sects ? 1 : 0;
        my $sizeofcmds = 0;
        if ( $self->type eq 'shared' ) {
            $sizeofcmds = 152 + 152 + 72 + length($lc_id_dylib) + 48 + 24 + 80;
        }
        else {
            $sizeofcmds = 72 + 152 + 152 + 24;    # PAGEZERO, TEXT, DATA, MAIN
        }
        $sizeofcmds += 72 + 80 * scalar(@debug_sects) if @debug_sects;
        open my $fh, '>', $f or die $!;
        binmode $fh;
        my $flags = 0x200085;
        $flags = 0x100085 if $self->type eq 'shared';    # MH_DYLIB | NOUNDEFS | TWOLEVEL
        print $fh pack( 'L<L<L<L<L<L<L<L<', 0xfeedfacf, $cputype, $cpusubtype, $filetype, $ncmds, $sizeofcmds, $flags, 0 );
        if ( $self->type ne 'shared' ) {
            print $fh pack( 'L<L< a16 Q<Q< Q<Q< L<L<L<L<', 0x19, 72, "__PAGEZERO", 0, $base, 0, 0, 0, 0, 0, 0 );
        }
        my $t_sec          = $l->get('.text');
        my $t_size_aligned = ( $t_sec->{size} + $page_size - 1 ) & ~( $page_size - 1 );
        print $fh pack(
            'L<L< a16 Q<Q< Q<Q< L<L<L<L<',
            0x19, 152, "__TEXT", $base, $t_sec->{rva} + $t_size_aligned,
            0,    $t_sec->{off} + $t_size_aligned,
            5,    5, 1, 0
        );
        print $fh pack(
            'a16 a16 Q<Q< L<L< L<L<L< L<L< L<',
            "__text", "__TEXT", $base + $t_sec->{rva},
            $t_sec->{size}, $t_sec->{off}, 4, 0, 0, 0x80000400, 0, 0, 0
        );
        my $d_sec          = $l->get('.data');
        my $d_size_aligned = ( $d_sec->{size} + $page_size - 1 ) & ~( $page_size - 1 );
        print $fh pack(
            'L<L< a16 Q<Q< Q<Q< L<L<L<L<',
            0x19, 152, "__DATA", $base + $d_sec->{rva},
            $d_size_aligned, $d_sec->{off}, $d_size_aligned, 3, 3, 1, 0
        );
        print $fh
            pack( 'a16 a16 Q<Q< L<L< L<L<L< L<L< L<', "__data", "__DATA", $base + $d_sec->{rva}, $d_sec->{size}, $d_sec->{off}, 3, 0, 0, 0, 0, 0, 0 );

        if ( $self->type eq 'shared' ) {
            my $le_sec          = $l->get('.linkedit');
            my $le_size_aligned = ( $le_sec->{size} + $page_size - 1 ) & ~( $page_size - 1 );
            print $fh pack(
                'L<L< a16 Q<Q< Q<Q< L<L<L<L<',
                0x19, 72, "__LINKEDIT", $base + $le_sec->{rva},
                $le_size_aligned, $le_sec->{off}, $le_sec->{size}, 1, 1, 0, 0
            );
            print $fh $lc_id_dylib;

            # LC_DYLD_INFO_ONLY
            print $fh pack( 'L<L< L<L< L<L< L<L< L<L< L<L<', 0x80000022, 48, 0, 0, 0, 0, 0, 0, 0, 0, $le_off, $trie_size );

            # LC_SYMTAB
            print $fh pack( 'L<L< L<L< L<L<', 0x2, 24, $le_off + $trie_size, $num_syms, $le_off + $trie_size + $symtab_size, $strtab_size );

            # LC_DYSYMTAB
            print $fh pack( 'L<L< L<L< L<L< L<L< L<L<', 0xB, 80, 0, 0, 0, $num_syms, $num_syms, 0 ) . ( "\0" x 48 );
        }
        else {
            # LC_MAIN
            print $fh pack( 'L<L< Q<Q< Q<', 0x80000028, 24, $t_sec->{off}, 0, 0 );
        }
        if (@debug_sects) {
            my $cmdsize      = 72 + 80 * scalar(@debug_sects);
            my $dw_start_rva = $debug_sects[0]->{rva};
            my $dw_start_off = $debug_sects[0]->{off};
            my $dw_size      = 0;
            for (@debug_sects) { $dw_size += $_->{size}; }
            my $dw_size_aligned = ( $dw_size + $page_size - 1 ) & ~( $page_size - 1 );
            print $fh pack(
                'L<L< a16 Q<Q< Q<Q< L<L<L<L<',
                0x19, $cmdsize, "__DWARF", $base + $dw_start_rva,
                $dw_size_aligned, $dw_start_off, $dw_size_aligned, 0, 0, scalar(@debug_sects), 0
            );
            for my $s (@debug_sects) {
                ( my $macho_name = $s->{name} ) =~ s/^\./__/;
                print $fh
                    pack( 'a16 a16 Q<Q< L<L< L<L<L< L<L< L<', $macho_name, "__DWARF", $base + $s->{rva}, $s->{size}, $s->{off}, 0, 0, 0, 0, 0, 0, 0 );
            }
        }
        print $fh ( "\0" x ( $t_sec->{off} - tell($fh) ) );
        print $fh $text . ( "\0" x ( $t_size_aligned - length($text) ) );
        my $d_payload = $data // '';
        print $fh $d_payload . ( "\0" x ( $d_sec->{off} + $d_size_aligned - tell($fh) ) );
        if ( $self->type eq 'shared' ) {
            print $fh ( "\0" x ( $l->get('.linkedit')->{off} - tell($fh) ) );
            print $fh $trie . $symtab . $strtab;
        }
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
