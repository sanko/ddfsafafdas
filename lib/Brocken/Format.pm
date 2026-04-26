package Brocken::Format {
    use v5.40;
    use utf8;
    use feature 'class';
    no warnings 'portable', 'experimental::class';

    class Brocken::Format {
        method write_bin( $f, $t, $d, $a, $o ) {...}
        method rva_for    ( $section, $arch, $os ) { return 0; }
        method import_rva ($name)                  { die 'Imports not supported by this format'; }
    }

    class Brocken::Format::Layout {
        field $base_addr      : param = 0;
        field $file_align     : param = 512;
        field $section_align  : param = 4096;
        field @sections;
        field $header_size = 0;
        field $total_vm_size = 0;

        method add_section($name, $data, $flags = 0) {
            push @sections, { name => $name, data => $data, flags => $flags };
        }
        method set_header_size($size) { $header_size = $size; }
        method calculate() {
            my $current_file_off = $self->align($header_size, $file_align);
            my $current_rva      = $self->align($header_size, $section_align);
            for my $s (@sections) {
                $s->{file_offset}  = $current_file_off;
                $s->{rva}          = $current_rva;
                $s->{raw_size}     = length($s->{data});
                $s->{padded_size}  = $self->align($s->{raw_size}, $file_align);
                $s->{vmsize}       = $self->align($s->{raw_size}, $section_align);
                $current_file_off += $s->{padded_size};
                $current_rva      += $s->{vmsize};
            }
            $total_vm_size = $current_rva;
        }
        method align($v, $a) { ($v + $a - 1) & ~($a - 1) }
        method section($name) {
            for (@sections) { return $_ if $_->{name} eq $name }
            return undef;
        }
        method sections() { @sections }
        method total_file_size() {
            return 0 unless @sections;
            my $last = $sections[-1];
            return $last->{file_offset} + $last->{padded_size};
        }
        method total_vm_size() { return $total_vm_size }
    }

    class Brocken::Format::MachO : isa(Brocken::Format) {
        method rva_for ( $section, $arch, $os ) {
            my $page_size = ( $arch eq 'arm64' ? 0x4000 : 0x1000 );
            return $page_size     if $section eq '.text';
            return 2 * $page_size if $section eq '.data';
            return 0;
        }
        method write_bin ( $filename, $text, $data, $arch, $os = 'macos' ) {
            my $is_arm    = ( $arch eq 'arm64' );
            my $page_size = $is_arm ? 0x4000 : 0x1000;
            my $layout    = Brocken::Format::Layout->new( file_align => $page_size, section_align => $page_size );
            $layout->add_section('__text', $text);
            $layout->add_section('__data', $data);
            $layout->set_header_size($page_size); 
            $layout->calculate();
            # ... rest of MachO implementation ...

            my $cpu_type    = $is_arm ? 0x0100000C : 0x01000007;
            my $cpu_subtype = $is_arm ? 0x00000000 : 0x00000003;
            my $ncmds       = 12;
            my $sizeofcmds  = 760;
            my $header      = pack( 'L L L L L L L L', 0xFEEDFACF, $cpu_type, $cpu_subtype, 2, $ncmds, $sizeofcmds, 0x00200085, 0 );
            my $lc_pagezero = pack( 'L L a16 Q Q Q Q L L L L', 0x19, 72, '__PAGEZERO', 0, 0x100000000, 0, 0, 0, 0, 0, 0 );

            my $s_text = $layout->section('__text');
            my $lc_text = pack( 'L L a16 Q Q Q Q L L L L', 0x19, 152, '__TEXT', 0x100000000, $s_text->{vmsize} + $page_size, 0, $s_text->{vmsize} + $page_size, 5, 5, 1, 0 );
            $lc_text .= pack( 'a16 a16 Q Q L L L L L L L L', '__text', '__TEXT', 0x100000000 + $s_text->{rva}, $s_text->{raw_size}, $s_text->{file_offset}, $is_arm ? 14 : 12, 0, 0, 0, $is_arm ? 0x80000400 : 0x00000400, 0, 0, 0 );

            my $s_data = $layout->section('__data');
            my $lc_data = pack( 'L L a16 Q Q Q Q L L L L', 0x19, 152, '__DATA', 0x100000000 + $s_data->{rva}, $s_data->{vmsize}, $s_data->{file_offset}, $s_data->{vmsize}, 3, 3, 1, 0 );
            $lc_data .= pack( 'a16 a16 Q Q L L L L L L L L', '__data', '__DATA', 0x100000000 + $s_data->{rva}, $s_data->{raw_size}, $s_data->{file_offset}, $is_arm ? 14 : 12, 0, 0, 0, 0, 0, 0, 0 );

            my $link_fileoff = $layout->total_file_size();
            my $lc_linkedit  = pack( 'L L a16 Q Q Q Q L L L L', 0x19, 72, '__LINKEDIT', 0x100000000 + $link_fileoff, $page_size, $link_fileoff, $page_size, 1, 1, 0, 0 );
            my $lc_main      = pack( 'L L Q Q', 0x80000028, 24, $s_text->{rva}, 0 );
            my $lc_build     = pack( 'L L L L L L', 0x32, 24, 1, 0x000B0000, 0x000B0000, 0 );
            my $lc_uuid      = pack( 'L L a16', 0x1B, 24, pack( 'H*', 'C0FFEE' . '0' x 26 ) );
            my $lc_dyld      = pack( 'L L L a20', 0x0E, 32, 12, '/usr/lib/dyld' );
            my $lc_dylib     = pack( 'L L L L L L a32', 0x0C, 56, 24, 2, 0x01000000, 0x01000000, '/usr/lib/libSystem.B.dylib' );
            my $lc_symtab    = pack( 'L L L L L L', 0x02, 24, $link_fileoff, 0, $link_fileoff, 0 );
            my $lc_dysymtab  = pack( 'L L' . 'L' x 18, 0x0B, 80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 );
            my $lc_dyld_info = pack( 'L L L L L L L L L L L L', 0x80000022, 48, $link_fileoff, 0, $link_fileoff, 0, $link_fileoff, 0, $link_fileoff, 0, $link_fileoff, 0 );

            open my $fh, '>', $filename or die $!; binmode $fh;
            print $fh $header, $lc_pagezero, $lc_text, $lc_data, $lc_linkedit, $lc_main, $lc_build, $lc_uuid, $lc_dyld, $lc_dylib, $lc_symtab, $lc_dysymtab, $lc_dyld_info;
            print $fh ( "\0" x ( $page_size - tell($fh) ) );
            for my $s ($layout->sections) {
                print $fh $s->{data}, ( "\0" x ( $s->{padded_size} - length($s->{data}) ) );
            }
            print $fh ( "\0" x $page_size );
            close $fh;
            chmod 0755, $filename;
            if ( $^O eq 'darwin' ) { system("codesign --force --sign - \"$filename\" >/dev/null 2>&1"); }
            return $filename;
        }
    }

    class Brocken::Format::ELF : isa(Brocken::Format) {
        method rva_for ( $section, $arch, $os ) {
            return 0x10000 if $section eq '.text';
            return 0x20000 if $section eq '.data';
            return 0;
        }
        method write_bin ( $filename, $text, $data, $arch, $os = 'linux' ) {
            my $base   = 0x400000;
            my $layout = Brocken::Format::Layout->new( file_align => 0x1000, section_align => 0x10000 );
            $layout->add_section('.text', $text);
            $layout->add_section('.data', $data);
            $layout->set_header_size(176); # ELF HDR + 2 PH
            $layout->calculate();

            my $machine = ( $arch eq 'arm64' ) ? 183 : 62;
            my $s_text  = $layout->section('.text');
            my $elf_hdr = pack( 'A4 C C C C C x7 S S L Q Q Q L S S S S S S', "\x7fELF", 2, 1, 1, 0, 0, 2, $machine, 1, $base + $s_text->{rva}, 64, 0, 0, 64, 56, 2, 0, 0, 0 );
            my $ph_text = pack( 'LL Q Q Q Q Q Q', 1, 5, $s_text->{file_offset}, $base + $s_text->{rva}, $base + $s_text->{rva}, $s_text->{raw_size}, $s_text->{raw_size}, 0x1000 );
            my $s_data  = $layout->section('.data');
            my $ph_data = pack( 'LL Q Q Q Q Q Q', 1, 6, $s_data->{file_offset}, $base + $s_data->{rva}, $base + $s_data->{rva}, $s_data->{raw_size}, $s_data->{raw_size}, 0x1000 );

            open my $fh, '>', $filename or die $!; binmode $fh;
            print $fh $elf_hdr, $ph_text, $ph_data;
            for my $s ($layout->sections) {
                print $fh ( "\0" x ( $s->{file_offset} - tell($fh) ) );
                print $fh $s->{data};
            }
            close $fh;
            chmod 0755, $filename;
            return $filename;
        }
    }

    class Brocken::Format::PE : isa(Brocken::Format) {
        our %IMPORTS = ( ExitProcess => 0, GetStdHandle => 8, WriteFile => 16, VirtualAlloc => 24, SetConsoleOutputCP => 32, AddVectoredExceptionHandler => 40 );
        method rva_for ( $section, $arch, $os ) {
            return 0x1000 if $section eq '.text';
            return 0x2000 if $section eq '.data';
            return 0x3000 if $section eq '.idata';
            return 0;
        }
        method import_rva ($name) {
            die 'Unknown PE import: ' . $name unless exists $IMPORTS{$name};
            return $self->rva_for( '.idata', 'x64', 'win64' ) + $IMPORTS{$name};
        }
        method write_bin ( $filename, $text, $data, $arch, $os = 'win64' ) {
            $data = "\0" x 8 if length($data) == 0;
            my $idata_rva = $self->rva_for('.idata', $arch, $os);
            my @funcs     = qw[ExitProcess GetStdHandle WriteFile VirtualAlloc SetConsoleOutputCP AddVectoredExceptionHandler];
            my $iat_size  = ( @funcs + 1 ) * 8;
            my ($iat_data, $hn_data) = ('', '');
            my $rva_hn    = $idata_rva + ( $iat_size * 2 ) + 40 + 16;
            for my $fn (@funcs) {
                $iat_data .= pack( 'Q<', $rva_hn + length($hn_data) );
                my $hn_entry = pack( 'S<', 0 ) . $fn . "\0"; $hn_entry .= "\0" if length($hn_entry) % 2 != 0;
                $hn_data .= $hn_entry;
            }
            $iat_data .= pack( 'Q<', 0 );
            my $import_dir = pack( 'L< L< L< L< L<', $idata_rva + $iat_size, 0, 0, $idata_rva + ( $iat_size * 2 ) + 40, $idata_rva ) . ( "\0" x 20 );
            my $idata_raw  = $iat_data . $iat_data . $import_dir . pack( 'a16', 'kernel32.dll' ) . $hn_data;

            my $layout = Brocken::Format::Layout->new( file_align => 0x200, section_align => 0x1000 );
            $layout->add_section('.text',  $text);
            $layout->add_section('.data',  $data);
            $layout->add_section('.idata', $idata_raw);
            $layout->set_header_size(0x200); # EXACTLY 512 bytes
            $layout->calculate();

            my $image_base = hex '140000000';
            my $machine    = ( $arch eq 'arm64' ) ? 0xAA64 : 0x8664;
            my $s_text     = $layout->section('.text');
            my $s_data     = $layout->section('.data');
            my $s_idata    = $layout->section('.idata');

            my $headers_bin = pack( 'S< x58 L<', 0x5A4D, 0x80 ) . pack( 'a64', "This program cannot be run in DOS mode.\n\$" );
            my $file_hdr    = pack( 'S< S< L< L< L< S< S<', $machine, 3, time(), 0, 0, 240, 0x0022 );
            my $opt_hdr     = pack( 'S< C C L< L< L< L< L< Q< L< L< S< S< S< S< S< S< L< L< L< L< S< S< Q< Q< Q< Q< L< L<',
                0x20B, 14, 0, $s_text->{padded_size}, $s_data->{padded_size} + $s_idata->{padded_size}, 0, $s_text->{rva}, $s_text->{rva}, $image_base, 0x1000, 0x200, 6, 0, 0, 0, 6, 0, 0, $layout->total_vm_size(), 0x200, 0, 3, 0x8100, 0x100000, 0x1000, 0x100000, 0x1000, 0, 16 );
            my $data_dirs = pack( 'L< L<', 0, 0 ) . pack( 'L< L<', $s_idata->{rva} + ( $iat_size * 2 ), 40 ) . ( pack( 'L< L<', 0, 0 ) x 10 ) . pack( 'L< L<', $s_idata->{rva}, $iat_size ) . ( pack( 'L< L<', 0, 0 ) x 3 );
            my $sec_text  = pack( 'a8 L< L< L< L< L< L< S< S< L<', '.text', $s_text->{raw_size}, $s_text->{rva}, $s_text->{padded_size}, $s_text->{file_offset}, 0, 0, 0, 0, 0x60000020 );
            my $sec_data  = pack( 'a8 L< L< L< L< L< L< S< S< L<', '.data', $s_data->{raw_size}, $s_data->{rva}, $s_data->{padded_size}, $s_data->{file_offset}, 0, 0, 0, 0, 0xC0000040 );
            my $sec_idata = pack( 'a8 L< L< L< L< L< L< S< S< L<', '.idata', $s_idata->{raw_size}, $s_idata->{rva}, $s_idata->{padded_size}, $s_idata->{file_offset}, 0, 0, 0, 0, 0xC0000040 );

            my $full_header = $headers_bin . pack( 'L<', 0x00004550 ) . $file_hdr . $opt_hdr . $data_dirs . $sec_text . $sec_data . $sec_idata;
            $full_header .= ( "\0" x ( 0x200 - length($full_header) ) );
            substr( $full_header, 0xD4, 4, pack( 'L<', length($full_header) ) );

            open my $fh, '>', $filename or die $!; binmode $fh;
            print $fh $full_header;
            for my $s ($layout->sections) {
                print $fh $s->{data}, ( "\0" x ( $s->{padded_size} - length($s->{data}) ) );
            }
            close $fh;
            return $filename;
        }
    }
};
1;
