package Brocken::Format::PE {
    use v5.40;
    use feature 'class';
    no warnings 'portable';
    no warnings 'experimental::class';

    class Brocken::Format::PE : isa(Brocken::Format) {
        our %IMPORTS = (
            ExitProcess                 => 0,
            GetStdHandle                => 8,
            WriteFile                   => 16,
            VirtualAlloc                => 24,
            SetConsoleOutputCP          => 32,
            AddVectoredExceptionHandler => 40
        );

        method import_rva($n) {
            return $self->rva_for('.idata') + ( $IMPORTS{$n} // die "Unknown PE import: $n" );
        }

        method _setup_layout( $l, $t, $d, $a, $o, $dbg = 0 ) {
            $l->add_section( '.text',  $t,                    0x60000020 );
            $l->add_section( '.data',  ( $d > 0 ? $d : 512 ), 0xC0000040 );
            $l->add_section( '.idata', 2048,                  0xC0000040 );
            if ( $dbg >= 1 ) {
                $l->add_section( '.debug_line',     4096, 0x42000040 );
                $l->add_section( '.debug_info',     8192, 0x42000040 );
                $l->add_section( '.debug_abbrev',   4096, 0x42000040 );
                $l->add_section( '.debug_frame',    8192, 0x42000040 );
                $l->add_section( '.debug_aranges',  4096, 0x42000040 );
                $l->add_section( '.debug_pubnames', 4096, 0x42000040 );
                if ( $o eq 'win64' ) {
                    $l->add_section( '.pdata', 4096, 0x42000040 );
                    $l->add_section( '.xdata', 4096, 0x42000040 );
                }
            }
        }
        method image_base () { return 0x140000000; }

        method write_bin( $filename, $text, $data, $arch, $os ) {
            my $l         = $self->layout;
            my $fa        = $l->file_align;
            my $sa        = $l->section_align;
            my $base      = $self->image_base;
            my $idata_rva = $l->get('.idata')->{rva};
            my $idata_raw = $self->_build_idata_raw($idata_rva);

            # Build SEH .pdata / .xdata sections
            my ( $pdata_data, $xdata_data ) = ( '', '' );
            my $pdata_rva  = 0;
            my $pdata_size = 0;
            if ( $os eq 'win64' && $self->func_ranges && @{ $self->func_ranges } ) {
                $xdata_data               = $self->_build_xdata;
                $pdata_data               = $self->_build_pdata( $l->get('.text')->{rva}, $l->get('.xdata')->{rva} );
                $l->get('.pdata')->{size} = length($pdata_data);
                $l->get('.xdata')->{size} = length($xdata_data);
                $pdata_rva                = $l->get('.pdata')->{rva};
                $pdata_size               = length($pdata_data);
            }
            my $image_size = $l->calculate(0x1000);
            my $m_type     = ( $arch eq 'arm64' ? 0xAA64 : 0x8664 );
            open my $fh, '>', $filename or die $!;
            binmode $fh;
            print $fh pack( 'S< x58 L<', 0x5A4D, 0x80 ), pack( 'a64', "Brocken AOT\n\$" ), pack( 'L<', 0x4550 );

            # Build COFF string table for long section names
            my %sec_name;
            my $strtab = '';
            for my $s ( $l->sections ) {
                if ( length( $s->{name} ) > 8 ) {
                    $sec_name{ $s->{name} } = sprintf( "/%d", 4 + length($strtab) );
                    $strtab .= $s->{name} . "\0";
                }
                else { $sec_name{ $s->{name} } = $s->{name}; }
            }
            my $num_syms = length($strtab) ? 1                                                : 0;
            my $sym_off  = $num_syms       ? ( 132 + 20 + 240 + scalar( $l->sections ) * 40 ) : 0;
            print $fh pack( 'S< S< L< L< L< S< S<', $m_type, scalar( $l->sections ), time(), $sym_off, $num_syms, 240, 0x0022 );

            # Optional Header
            my $soc  = ( $l->get('.text')->{size} + $fa - 1 ) & ~( $fa - 1 );
            my $soid = 0;
            for my $s ( $l->sections ) {
                $soid += ( $s->{size} + $fa - 1 ) & ~( $fa - 1 ) if $s->{flags} & 0x40;
            }
            print $fh pack(
                'S< C C L< L< L< L< L< Q< L< L< S< S< S< S< S< S< L< L< L< L< S< S< Q< Q< Q< Q< L< L<',
                0x20B, 14, 0, $soc, $soid, 0,
                $l->get('.text')->{rva},
                $l->get('.text')->{rva},
                $base, $sa, $fa, 6, 0, 0, 0, 6, 0, 0, $image_size, $l->header_size, 0, 3, 0x8100, 0x100000, $sa, 0x100000, $sa, 0, 16
            );

            # Data Directory Entries (16 standard entries)
            print $fh pack( 'L< L<', 0,                0 );              # 0: Export
            print $fh pack( 'L< L<', $idata_rva + 256, 40 );             # 1: Import
            print $fh pack( 'L< L<', 0,                0 );              # 2: Resource
            print $fh pack( 'L< L<', $pdata_rva,       $pdata_size );    # 3: Exception (.pdata)
            print $fh ( pack( 'L< L<', 0, 0 ) x 8 );                     # 4-11: reserved
            print $fh pack( 'L< L<', $idata_rva, 64 );                   # 12: IAT
            print $fh ( pack( 'L< L<', 0, 0 ) x 3 );                     # 13-15: reserved

            for my $s ( $l->sections ) {
                my $raw_size = ( $s->{size} + $fa - 1 ) & ~( $fa - 1 );
                print $fh pack(
                    'a8 L< L< L< L< L< L< S< S< L<',
                    $sec_name{ $s->{name} },
                    $s->{size}, $s->{rva}, $raw_size, $s->{off}, 0, 0, 0, 0, $s->{flags}
                );
            }
            if ($num_syms) {
                print $fh pack('x18');                                    # 1 dummy COFF symbol entry (18 null bytes)
                print $fh pack( 'L<', length($strtab) + 4 ) . $strtab;    # string table
            }
            print $fh ( "\0" x ( $l->header_size - tell($fh) ) );
            for my $s ( $l->sections ) {
                my $payload
                    = $s->{name} eq '.text' ? $text :
                    $s->{name} eq '.idata'  ? $idata_raw :
                    $s->{name} eq '.pdata'  ? $pdata_data :
                    $s->{name} eq '.xdata'  ? $xdata_data :
                    ( $s->{name} =~ /^\.debug/ ? ( $self->debug_section( $s->{name} ) || "\0" ) : ( $data || "\0" ) );
                my $file_size = ( $s->{size} + $fa - 1 ) & ~( $fa - 1 );
                $payload .= "\0" x ( $file_size - length($payload) ) if length($payload) < $file_size;
                $payload = substr( $payload, 0, $file_size );
                seek( $fh, $s->{off}, 0 );
                print $fh $payload;
            }
            close $fh;
            return $filename;
        }

        method _build_idata_raw($base_rva) {
            my @funcs = qw[ExitProcess GetStdHandle WriteFile VirtualAlloc SetConsoleOutputCP AddVectoredExceptionHandler];
            my ( $iat, $hints ) = ( '', '' );
            my $hints_rva = $base_rva + 320;
            for my $f (@funcs) {
                $iat   .= pack( 'Q<', $hints_rva + length($hints) );
                $hints .= pack( 'S<', 0 ) . $f . "\0";
                $hints .= "\0" if length($hints) % 2 != 0;
            }
            $iat .= pack( 'Q<', 0 );
            my $ilt   = $iat;
            my $dir   = pack( 'L< L< L< L< L<', $base_rva + 128, 0, 0, $base_rva + 296, $base_rva );
            my $block = $iat . ( "\0" x ( 128 - length($iat) ) ) . $ilt . ( "\0" x ( 128 - length($ilt) ) ) . $dir . ( "\0" x 20 );
            $block .= "kernel32.dll\0";
            $block .= ( "\0" x ( 320 - length($block) ) ) . $hints;
            return $block . ( "\0" x ( 2048 - length($block) ) );
        }

        # --- SEH .pdata / .xdata builders ---
        method _build_xdata () {
            my $FRAME  = 1064;          # frame_local_size on win64
            my $scaled = $FRAME / 8;    # = 133

            # UNWIND_INFO header (4 bytes)
            my $hdr = pack( 'v', (1) | ( 0 << 3 ) | ( 22 << 6 ) );
            $hdr .= pack( 'C', 11 );    # CountOfCodes
            $hdr .= pack( 'C', 0 );     # FrameRegister=0, FrameOffset=0

            # Unwind codes in descending CodeOffset order + padding
            my $codes = pack( 'CC', 15, 0x01 );    # UWOP_ALLOC_LARGE, OpInfo=0
            $codes .= pack( 'S<', $scaled );       # scaled alloc size follows
            $codes .= pack( 'CC', 12, 0x30 );      # UWOP_SET_FPREG
            $codes .= pack( 'CC', 10, 0xF0 );      # UWOP_PUSH_NONVOL r15
            $codes .= pack( 'CC', 8,  0xE0 );      # UWOP_PUSH_NONVOL r14
            $codes .= pack( 'CC', 6,  0xD0 );      # UWOP_PUSH_NONVOL r13
            $codes .= pack( 'CC', 4,  0xC0 );      # UWOP_PUSH_NONVOL r12
            $codes .= pack( 'CC', 3,  0x60 );      # UWOP_PUSH_NONVOL rsi
            $codes .= pack( 'CC', 2,  0x70 );      # UWOP_PUSH_NONVOL rdi
            $codes .= pack( 'CC', 1,  0x30 );      # UWOP_PUSH_NONVOL rbx
            $codes .= pack( 'CC', 0,  0x50 );      # UWOP_PUSH_NONVOL rbp
            $codes .= pack( 'S<', 0 );             # padding to 4-byte alignment
            return $hdr . $codes;
        }

        method _build_pdata ( $text_rva, $xdata_rva ) {
            my $data = '';
            for my $fn ( sort { $a->{start} <=> $b->{start} } @{ $self->func_ranges } ) {
                $data .= pack(
                    'L< L< L<', $text_rva + $fn->{start},    # BeginAddress
                    $text_rva + $fn->{end},                  # EndAddress (exclusive)
                    $xdata_rva,                              # UnwindData (all entries share one UNWIND_INFO)
                );
            }
            return $data;
        }
    }
}
1;
__END__

=pod

=head1 NAME

Brocken::Format::PE - Windows PE64 binary format writer

=head1 DESCRIPTION

Builds a Windows Portable Executable (PE32+). Emits DOS header, NT headers (COFF + Optional Header), section table
(.text, .data, .idata), and import directory for kernel32.dll.

Six kernel32.dll functions are imported: ExitProcess, GetStdHandle, WriteFile, VirtualAlloc, SetConsoleOutputCP,
AddVectoredExceptionHandler.

=head1 METHODS

=head2 write_bin($filename, $text, $data, $arch, $os)

Writes the complete PE executable to disk.

=cut
}
1;
