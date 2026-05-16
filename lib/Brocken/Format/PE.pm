package Brocken::Format::PE {
    use v5.40;
    use feature 'class';
    no warnings 'portable';
    no warnings 'experimental::class';
    use File::Basename qw(basename);

    class Brocken::Format::PE : isa(Brocken::Format) {
        our %IMPORTS = (
            ExitProcess                 => 0,
            GetStdHandle                => 8,
            WriteFile                   => 16,
            VirtualAlloc                => 24,
            SetConsoleOutputCP          => 32,
            AddVectoredExceptionHandler => 40,
            CreateEventA                => 48,
            SetEvent                    => 56,
            WaitForSingleObject         => 64,
            CloseHandle                 => 72,
            CreateFileA                 => 80,
            ReadFile                    => 88,
            GetFileSizeEx               => 96
        );

        method import_rva($n) {
            return $self->rva_for('.idata') + ( $IMPORTS{$n} // die "Unknown PE import: $n" );
        }

        method _setup_layout( $l, $t, $d, $a, $o, $dbg = 0 ) {
            $l->add_section( '.text',  $t,                    0x60000020 );
            $l->add_section( '.data',  ( $d > 0 ? $d : 512 ), 0xC0000040 );
            $l->add_section( '.idata', 2048,                  0xC0000040 );
            #
            if ( $self->type eq 'shared' ) {
                warn "PE: Adding .edata section\n" if $ENV{BROCKEN_JIT_DEBUG};
                $l->add_section( '.edata', 2048, 0x40000040 );
            }
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

        method write_bin( $filename, $text, $data, $arch, $os, $type ) {
            warn "PE: write_bin start\n" if $ENV{BROCKEN_JIT_DEBUG};
            my $l         = $self->layout;
            my $fa        = $l->file_align;
            my $sa        = $l->section_align;
            my $base      = $self->image_base;
            my $idata_rva = $l->get('.idata')->{rva};
            my $idata_raw = $self->_build_idata_raw($idata_rva);
            warn "PE: idata built\n" if $ENV{BROCKEN_JIT_DEBUG};
            my ( $edata_data, $edata_rva, $edata_size ) = ( '', 0, 0 );

            if ( $self->type eq 'shared' ) {
                warn "PE: building edata...\n" if $ENV{BROCKEN_JIT_DEBUG};
                $edata_rva                = $l->get('.edata')->{rva};
                $edata_data               = $self->_build_edata_raw( $edata_rva, $filename );
                $edata_size               = length($edata_data);
                $l->get('.edata')->{size} = $edata_size;
                $l->calculate(0x1000);    # Recalculate offsets/RVAs
                warn "PE: edata built, size=$edata_size\n" if $ENV{BROCKEN_JIT_DEBUG};
            }

            # Build SEH .pdata / .xdata sections
            my ( $pdata_data, $xdata_data ) = ( '', '' );
            my $pdata_rva  = 0;
            my $pdata_size = 0;
            if ( $os eq 'win64' && $self->func_ranges && @{ $self->func_ranges } ) {
                warn "PE: building SEH...\n" if $ENV{BROCKEN_JIT_DEBUG};
                $xdata_data               = $self->_build_xdata;
                $pdata_data               = $self->_build_pdata( $l->get('.text')->{rva}, $l->get('.xdata')->{rva} );
                $l->get('.pdata')->{size} = length($pdata_data);
                $l->get('.xdata')->{size} = length($xdata_data);
                $pdata_rva                = $l->get('.pdata')->{rva};
                $pdata_size               = length($pdata_data);
            }
            if ( $ENV{BROCKEN_JIT_DEBUG} ) {
                for my $s ( $l->sections ) {
                    warn "PE: Section " . $s->{name} . " size=" . $s->{size} . "\n";
                }
            }
            my $image_size = $l->calculate(0x1000);
            warn "PE: layout calculated, image_size=$image_size\n" if $ENV{BROCKEN_JIT_DEBUG};
            my $m_type = ( $arch eq 'arm64' ? 0xAA64 : 0x8664 );
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
            my $num_syms        = length($strtab)             ? 1                                                : 0;
            my $sym_off         = $num_syms                   ? ( 132 + 20 + 240 + scalar( $l->sections ) * 40 ) : 0;
            my $characteristics = ( $self->type eq 'shared' ) ? 0x2022                                           : 0x0022;
            print $fh pack( 'S< S< L< L< L< S< S<', $m_type, scalar( $l->sections ), time(), $sym_off, $num_syms, 240, $characteristics );

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
            #~ my ($edata_data, $edata_rva, $edata_size) = ('', 0, 0);
            #~ if ($self->type eq 'shared') {
            #~ my $edata = $l->get('.edata');
            #~ }
            print $fh pack( 'L< L<', $edata_rva,       $edata_size );    # 0: Export
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
                    $s->{name} eq '.edata'  ? $edata_data :
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
            my @funcs = sort { $IMPORTS{$a} <=> $IMPORTS{$b} } keys %IMPORTS;
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

        method _build_xdata () {
            my $locals      = 1024;
            my $ctx         = 64;                  # 8 preserved regs on Win64
            my $shadow      = 32;
            my $target_size = $locals + $shadow;
            my $rem         = ( 8 - $ctx ) % 16;
            $rem += 16 if $rem < 0;
            my $align_padding = ( $rem - ( $target_size % 16 ) ) % 16;
            $align_padding += 16 if $align_padding < 0;
            my $FRAME  = $target_size + $align_padding;
            my $scaled = $FRAME / 8;
            my $hdr    = pack( 'C C C C', 1, 22, 10, 0 );
            my $codes  = pack( 'CC', 22, 0x01 );
            $codes .= pack( 'S<', $scaled );
            $codes .= pack( 'CC', 12, 0xF0 );
            $codes .= pack( 'CC', 10, 0xE0 );
            $codes .= pack( 'CC', 8,  0xD0 );
            $codes .= pack( 'CC', 6,  0xC0 );
            $codes .= pack( 'CC', 4,  0x60 );
            $codes .= pack( 'CC', 3,  0x70 );
            $codes .= pack( 'CC', 2,  0x30 );
            $codes .= pack( 'CC', 1,  0x50 );
            return $hdr . $codes;
        }

        method _build_pdata ( $text_rva, $xdata_rva ) {
            my $data = '';
            for my $fn ( sort { $a->{start} <=> $b->{start} } @{ $self->func_ranges } ) {
                $data .= pack( 'L< L< L<', $text_rva + $fn->{start}, $text_rva + $fn->{end}, $xdata_rva );
            }
            return $data;
        }

        method _build_edata_raw( $base_rva, $filename ) {
            my @exports     = @{ $self->exported_funcs // [] };
            my $num_exports = scalar @exports;
            return ( "\0" x 2048 ) if $num_exports == 0;
            my $eat_off       = 40;
            my $npt_off       = $eat_off + ( 4 * $num_exports );
            my $ot_off        = $npt_off + ( 4 * $num_exports );
            my $name_data_off = $ot_off + ( 2 * $num_exports );
            my $edat          = pack(
                'L< L< S< S< L< L< L< L< L< L< L<',
                0, time(),       0, 0, $base_rva + $name_data_off,
                1, $num_exports, $num_exports,
                $base_rva + $eat_off,
                $base_rva + $npt_off,
                $base_rva + $ot_off
            );
            my $eat       = '';
            my $npt       = '';
            my $ot        = '';
            my $name_data = basename($filename) . "\0";

            for my $i ( 0 .. $#exports ) {
                my $name         = $exports[$i];
                my $target_label = "E_$name";                        # Use the autoboxing thunk not the internal M_ function
                my $offset       = $self->labels->{$target_label};
                if ( !defined $offset ) {
                    warn "PE: Export label $target_label NOT FOUND in map!\n" if $ENV{BROCKEN_JIT_DEBUG};
                    $offset = 0;
                }
                my $rva = $self->rva_for('.text') + $offset;
                warn "PE: Export $name -> RVA " . sprintf( "0x%X", $rva ) . "\n" if $ENV{BROCKEN_JIT_DEBUG};
                $eat .= pack( 'L<', $rva );
                $npt .= pack( 'L<', $base_rva + $name_data_off + length($name_data) );
                $ot  .= pack( 'S<', $i );
                $name_data .= $name . "\0";
            }
            my $block   = $edat . $eat . $npt . $ot . $name_data;
            my $pad_len = 2048 - length($block);
            $pad_len = 0 if $pad_len < 0;
            return $block . ( "\0" x $pad_len );
        }
    }
}
1;
