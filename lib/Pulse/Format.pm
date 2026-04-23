package Pulse::Format {
    use v5.40;
    use utf8;
    use feature 'class';
    no warnings 'portable', 'experimental::class';
    #
    class Pulse::Format {
        method write_bin( $f, $t, $d, $a, $o ) {...}
    }

    class Pulse::Format::MachO : isa(Pulse::Format) {

        method write_bin ( $filename, $text, $data, $arch, $os = 'macos' ) {
            my $is_arm      = ( $arch eq 'arm64' );
            my $page_size   = $is_arm ? 0x4000     : 0x1000;
            my $cpu_type    = $is_arm ? 0x0100000C : 0x01000007;
            my $cpu_subtype = $is_arm ? 0x00000000 : 0x00000003;
            my $align_f     = sub { my ( $v, $a ) = @_; return ( $v + $a - 1 ) & ~( $a - 1 ); };
            my $text_padded = $text . ( "\0" x ( $align_f->( length($text), $page_size ) - length($text) ) );
            my $data_padded = $data . ( "\0" x ( $align_f->( length($data), $page_size ) - length($data) ) );
            my $ncmds       = 12;
            my $sizeofcmds  = 760;
            my $header      = pack( 'L L L L L L L L', 0xFEEDFACF, $cpu_type, $cpu_subtype, 2, $ncmds, $sizeofcmds, 0x00200085, 0 );
            my $lc_pagezero = pack( 'L L a16 Q Q Q Q L L L L', 0x19, 72, "__PAGEZERO", 0, 0x100000000, 0, 0, 0, 0, 0, 0 );
            my $text_vmsize = 2 * $page_size;
            my $lc_text     = pack( 'L L a16 Q Q Q Q L L L L', 0x19, 152, "__TEXT", 0x100000000, $text_vmsize, 0, $text_vmsize, 5, 5, 1, 0 );
            $lc_text .= pack(
                'a16 a16 Q Q L L L L L L L L',
                "__text", "__TEXT", 0x100000000 + $page_size,
                length($text_padded), $is_arm ? 14 : 12,
                $page_size, 0, 0, 0, $is_arm ? 0x80000400 : 0x00000400,
                0, 0, 0
            );
            my $data_vmaddr = 0x100000000 + 2 * $page_size;
            my $lc_data = pack( 'L L a16 Q Q Q Q L L L L', 0x19, 152, "__DATA", $data_vmaddr, $page_size, 2 * $page_size, $page_size, 3, 3, 1, 0 );
            $lc_data .= pack(
                'a16 a16 Q Q L L L L L L L L',
                "__data", "__DATA", $data_vmaddr, length($data_padded),
                $is_arm ? 14 : 12,
                2 * $page_size,
                0, 0, 0, 0, 0, 0, 0
            );
            my $link_vmaddr  = 0x100000000 + 3 * $page_size;
            my $link_fileoff = 3 * $page_size;
            my $lc_linkedit
                = pack( 'L L a16 Q Q Q Q L L L L', 0x19, 72, "__LINKEDIT", $link_vmaddr, $page_size, $link_fileoff, $page_size, 1, 1, 0, 0 );
            my $lc_main      = pack( 'L L Q Q',         0x80000028, 24, $page_size, 0 );
            my $lc_build     = pack( 'L L L L L L',     0x32,       24, 1, 0x000B0000, 0x000B0000, 0 );
            my $lc_uuid      = pack( 'L L a16',         0x1B,       24, pack( "H*", "C0FFEE" . "0" x 26 ) );
            my $lc_dyld      = pack( 'L L L a20',       0x0E,       32, 12,            "/usr/lib/dyld" );
            my $lc_dylib     = pack( 'L L L L L L a32', 0x0C,       56, 24,            2, 0x01000000,    0x01000000, "/usr/lib/libSystem.B.dylib" );
            my $lc_symtab    = pack( 'L L L L L L',     0x02,       24, $link_fileoff, 0, $link_fileoff, 0 );
            my $lc_dysymtab  = pack( 'L L' . 'L' x 18,  0x0B,       80, 0,             0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 );
            my $lc_dyld_info = pack( 'L L L L L L L L L L L L',
                0x80000022, 48, $link_fileoff, 0, $link_fileoff, 0, $link_fileoff, 0, $link_fileoff, 0, $link_fileoff, 0 );
            open my $fh, '>', $filename or die $!;
            binmode $fh;
            print $fh $header, $lc_pagezero, $lc_text, $lc_data, $lc_linkedit, $lc_main, $lc_build, $lc_uuid, $lc_dyld, $lc_dylib, $lc_symtab,
                $lc_dysymtab, $lc_dyld_info;
            print $fh ( "\0" x ( $page_size - ( length($header) + $sizeofcmds ) ) );
            print $fh $text_padded, $data_padded, ( "\0" x $page_size );
            close $fh;
            chmod 0755, $filename;
            if ( $^O eq 'darwin' ) { system("codesign --force --sign - \"$filename\" >/dev/null 2>&1"); }
            return $filename;
        }
    }

    class Pulse::Format::ELF : isa(Pulse::Format) {

        method write_bin ( $filename, $text, $data, $arch, $os = 'linux' ) {
            my $base        = 0x400000;
            my $text_off    = 0x1000;
            my $align_f     = sub { my ( $v, $a ) = @_; return ( $v + $a - 1 ) & ~( $a - 1 ); };
            my $text_padded = $text . ( "\0" x ( 0x1000 - ( length($text) % 0x1000 ) ) );
            if ( length($text_padded) > 0x1000 ) {
                die "Error: Milestone 5 code exceeds 4KB limit. Adjust text_off or ELF logic.";
            }
            my $data_off    = $text_off + length($text_padded);                                             # Will be 0x2000
            my $data_padded = $data . ( "\0" x ( $align_f->( length($data), 0x1000 ) - length($data) ) );
            my $machine     = ( $arch eq 'arm64' ) ? 183 : 62;
            my $elf_hdr     = pack(
                'A4 C C C C C x7 S S L Q Q Q L S S S S S S',
                "\x7fELF", 2, 1, 1,  0,  0, 2, $machine, 1, $base + $text_off,
                64,        0, 0, 64, 56, 2, 0, 0,        0
            );
            my $ph_text
                = pack( 'LL Q Q Q Q Q Q', 1, 5, $text_off, $base + $text_off, $base + $text_off, length($text_padded), length($text_padded), 0x1000 );
            my $ph_data
                = pack( 'LL Q Q Q Q Q Q', 1, 6, $data_off, $base + $data_off, $base + $data_off, length($data_padded), length($data_padded), 0x1000 );
            open my $fh, '>', $filename or die $!;
            binmode $fh;
            print $fh $elf_hdr, $ph_text, $ph_data;
            print $fh ( "\0" x ( $text_off - 176 ) );
            print $fh $text_padded, $data_padded;
            close $fh;
            chmod 0755, $filename;
            return $filename;
        }
    }

    class Pulse::Format::PE : isa(Pulse::Format) {

        method write_bin ( $filename, $text, $data, $arch, $os = 'win64' ) {

            # Setup and Alignment
            # Windows loader often fails if the data segment is completely empty
            $data = "\0" x 8 if length($data) == 0;
            my $fa         = 0x400;                                                               # File Alignment (1024 bytes) - Fixed for M5
            my $sa         = 0x1000;                                                              # Section Alignment (4096 bytes)
            my $image_base = hex '140000000';
            my $machine    = ( $arch eq 'arm64' ) ? 0xAA64 : 0x8664;
            my $align      = sub { my ( $v, $a ) = @_; return ( $v + $a - 1 ) & ~( $a - 1 ); };

            # RVAs (Relative Virtual Addresses)
            my $text_rva  = $sa;
            my $data_rva  = $sa * 2;
            my $idata_rva = $sa * 3;

            # Construct .idata (Import Table)
            # We need to import functions from kernel32.dll for printing and memory allocation
            my @funcs    = qw[ExitProcess GetStdHandle WriteFile VirtualAlloc SetConsoleOutputCP];
            my $iat_size = ( @funcs + 1 ) * 8;                                                       # 8 bytes per entry + null terminator
            my $iat_data = '';
            my $hn_data  = '';

            # Calculate where Hint/Name strings start in the file
            # Layout: IAT (Table) + ILT (Lookup Table) + Directory + DLL Name + Hint/Names
            my $rva_hn = $idata_rva + ( $iat_size * 2 ) + 40 + 16;
            for my $fn (@funcs) {
                $iat_data .= pack( 'Q<', $rva_hn + length($hn_data) );
                my $hn_entry = pack( 'S<', 0 ) . $fn . "\0";
                $hn_entry .= "\0" if length($hn_entry) % 2 != 0;    # Ensure word alignment
                $hn_data  .= $hn_entry;
            }
            $iat_data .= pack( 'Q<', 0 );                           # Null terminator for tables

            # Import Directory Table (20 bytes per entry + 20 bytes null terminator)
            my $import_dir = pack(
                'L< L< L< L< L<', $idata_rva + $iat_size,     # ILT RVA
                0, 0, $idata_rva + ( $iat_size * 2 ) + 40,    # DLL Name RVA
                $idata_rva                                    # IAT RVA
            ) . ( "\0" x 20 );
            my $idata_raw = $iat_data . $iat_data . $import_dir . pack( 'a16', 'kernel32.dll' ) . $hn_data;

            # Padded Segment Data
            my $text_padded  = $text .      ( "\0" x ( $align->( length($text),      $fa ) - length($text) ) );
            my $data_padded  = $data .      ( "\0" x ( $align->( length($data),      $fa ) - length($data) ) );
            my $idata_padded = $idata_raw . ( "\0" x ( $align->( length($idata_raw), $fa ) - length($idata_raw) ) );

            # PE Headers
            my $headers_bin = pack( 'S< x58 L<', 0x5A4D, 0x80 ) . pack( 'a64', "This program cannot be run in DOS mode.\n\$" );

            # COFF File Header
            my $file_hdr = pack( 'S< S< L< L< L< S< S<', $machine, 3, time(), 0, 0, 240, 0x0022 );

            # Optional Header
            my $opt_hdr = pack(
                'S< C C L< L< L< L< L< Q< L< L< S< S< S< S< S< S< L< L< L< L< S< S< Q< Q< Q< Q< L< L<', 0x20B, 14, 0, length($text_padded),
                length($data_padded) + length($idata_padded), 0, $text_rva, $text_rva, $image_base, $sa, $fa, 6, 0, 0, 0, 6, 0, 0,    # Versions
                $align->( $idata_rva + length($idata_padded), $sa ),    # SizeOfImage
                $fa,                                                    # SizeOfHeaders (will patch later)
                0, 3, 0x8100,                                           # Subsystem (Console), DllCharacteristics
                0x100000, 0x1000, 0x100000, 0x1000, 0, 16               # Stack/Heap reserve/commit
            );

            # Data Directories
            my $data_dirs = pack( 'L< L<', 0, 0 ) .                      # Export
                pack( 'L< L<', $idata_rva + ( $iat_size * 2 ), 40 ) .    # Import
                ( pack( 'L< L<', 0, 0 ) x 10 ) .                         # Misc
                pack( 'L< L<', $idata_rva, $iat_size ) .                 # IAT
                ( pack( 'L< L<', 0, 0 ) x 3 );

            # Section Headers
            my $sec_text
                = pack( 'a8 L< L< L< L< L< L< S< S< L<', '.text', length($text), $text_rva, length($text_padded), $fa, 0, 0, 0, 0, 0x60000020 );
            my $sec_data = pack(
                'a8 L< L< L< L< L< L< S< S< L<',
                '.data', length($data), $data_rva, length($data_padded), $fa + length($text_padded),
                0,       0,             0,         0,                    0xC0000040
            );
            my $sec_idata = pack(
                'a8 L< L< L< L< L< L< S< S< L<',
                '.idata', length($idata_raw), $idata_rva, length($idata_padded), $fa + length($text_padded) + length($data_padded),
                0,        0,                  0,          0,                     0xC0000040
            );

            # Final Assembly and Patching
            my $full_header = $headers_bin . pack( 'L<', 0x00004550 ) . $file_hdr . $opt_hdr . $data_dirs . $sec_text . $sec_data . $sec_idata;

            # Pad header to exactly FileAlignment ($fa)
            $full_header .= ( "\0" x ( $fa - length($full_header) ) );

            # Patch SizeOfHeaders (Offset 0xD4 in the resulting file)
            # This is critical for the Windows Loader
            substr( $full_header, 0xD4, 4, pack( 'L<', length($full_header) ) );

            # Write to disk
            open my $fh, '>', $filename or die "Could not open $filename for writing: $!";
            binmode $fh;
            print $fh $full_header, $text_padded, $data_padded, $idata_padded;
            close $fh;
            return $filename;
        }
    }
};
1;
