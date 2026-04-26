package Brocken::Format {
    use v5.40;
    use utf8;
    use feature 'class';
    no warnings 'portable', 'experimental::class';

    class Brocken::Format {
        field $_layout;
        method layout() { $_layout }
        method rva_for($name, @args) { return $_layout->get($name)->{rva} }

        method pre_layout($text_size, $data_size, $arch, $os) {
            $_layout = Brocken::Format::Layout->new(
                file_align    => ($os eq 'win64' ? 0x200 : 0x1000),
                section_align => 0x1000
            );
            $self->_setup_layout($_layout, $text_size, $data_size, $arch, $os);
            $_layout->calculate(0x1000);
        }
        method _setup_layout($l, $t, $d, $a, $o) { die "Abstract" }
    }

    class Brocken::Format::Layout {
        field $file_align    : param;
        field $section_align : param;
        field @sections;
        field $header_size   = 0;

        method add_section($name, $size, $flags) {
            push @sections, { name => $name, size => ($size || 1), flags => $flags, rva => 0, off => 0 };
        }

        method calculate($min_hdr) {
            $header_size = ($min_hdr + $file_align - 1) & ~($file_align - 1);
            my $curr_off = $header_size;
            my $curr_rva = 0x1000;
            for my $s (@sections) {
                $s->{off} = $curr_off;
                $s->{rva} = $curr_rva;
                $curr_off += ($s->{size} + $file_align - 1) & ~($file_align - 1);
                $curr_rva += ($s->{size} + $section_align - 1) & ~($section_align - 1);
            }
            return $curr_rva;
        }

        method get($n) {
            for (@sections) { return $_ if $_->{name} eq $n }
            my $map = { '.text' => '__text', '.data' => '__data', '.idata' => '__idata' };
            for (@sections) { return $_ if exists $map->{$n} && $_->{name} eq $map->{$n} }
            die "Layout Error: Section $n not found";
        }
        method sections()    { @sections }
        method header_size() { $header_size }
    }

    class Brocken::Format::PE : isa(Brocken::Format) {
        our %IMPORTS = ( ExitProcess => 0, GetStdHandle => 8, WriteFile => 16, VirtualAlloc => 24, SetConsoleOutputCP => 32, AddVectoredExceptionHandler => 40 );
        method import_rva($n) { return $self->rva_for('.idata') + $IMPORTS{$n} }

        method _setup_layout($l, $t, $d, $a, $o) {
            $l->add_section('.text',  $t, 0x60000020);
            $l->add_section('.data',  ($d > 0 ? $d : 512), 0xC0000040);
            $l->add_section('.idata', 2048, 0xC0000040);
        }

        method write_bin($filename, $text, $data, $arch, $os) {
            my $l = $self->layout;
            my $idata_rva = $l->get('.idata')->{rva};
            my $idata_raw = $self->_build_idata_raw($idata_rva);
            my $image_size = $l->calculate(0x1000);

            my $m_type = ($arch eq 'arm64' ? 0xAA64 : 0x8664);
            open my $fh, '>', $filename or die $!; binmode $fh;

            # 1. Header Signatures
            print $fh pack('S< x58 L<', 0x5A4D, 0x80), pack('a64', "Brocken AOT\n\$"), pack('L<', 0x4550);
            print $fh pack('S< S< L< L< L< S< S<', $m_type, scalar($l->sections), time(), 0, 0, 240, 0x0022);

            # 2. Optional Header
            print $fh pack('S< C C L< L< L< L< L< Q< L< L< S< S< S< S< S< S< L< L< L< L< S< S< Q< Q< Q< Q< L< L<',
                0x20B, 14, 0, $l->get('.text')->{size}, $l->get('.data')->{size} + length($idata_raw),
                0, $l->get('.text')->{rva}, $l->get('.text')->{rva}, 0x140000000, 0x1000, 0x200, 6, 0, 0, 0, 6, 0, 0,
                $image_size, $l->header_size, 0, 3, 0x8140, 0x100000, 0x1000, 0x100000, 0x1000, 0, 16 );

            # 3. Data Directories (CRITICAL FIX: Import Directory is exactly at offset 256)
            print $fh pack('L< L<', 0, 0), pack('L< L<', $idata_rva + 256, 40);
            print $fh (pack('L< L<', 0, 0) x 10);
            print $fh pack('L< L<', $idata_rva, 64), (pack('L< L<', 0, 0) x 3);

            # 4. Section Table
            for my $s ($l->sections) {
                my $file_size = ($s->{size} + 0x1FF) & ~0x1FF;
                print $fh pack('a8 L< L< L< L< L< L< S< S< L<', $s->{name}, $s->{size}, $s->{rva}, $file_size, $s->{off}, 0, 0, 0, 0, $s->{flags});
            }
            print $fh ("\0" x ($l->header_size - tell($fh)));

            # 5. Payload Writes (Strict Seeking AND Strict Padding)
            for my $s ($l->sections) {
                my $payload = $s->{name} eq '.text' ? $text : ($s->{name} eq '.idata' ? $idata_raw : ($data || "\0"));
                my $file_size = ($s->{size} + 0x1FF) & ~0x1FF;

                # CRITICAL: Force payload to be the EXACT size declared in the headers
                if (length($payload) < $file_size) {
                    $payload .= "\0" x ($file_size - length($payload));
                } else {
                    $payload = substr($payload, 0, $file_size);
                }

                seek($fh, $s->{off}, 0);
                print $fh $payload;
            }

            close $fh; return $filename;
        }

        method _build_idata_raw($base_rva) {
            my @funcs = qw[ExitProcess GetStdHandle WriteFile VirtualAlloc SetConsoleOutputCP AddVectoredExceptionHandler];
            my ($iat, $hints) = ('', '');

            my $hints_rva = $base_rva + 320;
            for my $f (@funcs) {
                $iat   .= pack('Q<', $hints_rva + length($hints));
                $hints .= pack('S<', 0) . $f . "\0";
                $hints .= "\0" if length($hints) % 2 != 0;
            }
            $iat .= pack('Q<', 0);

            my $ilt = $iat;
            my $dll_name_rva = $base_rva + 296;

            my $dir = pack('L< L< L< L< L<', $base_rva + 128, 0, 0, $dll_name_rva, $base_rva);

            my $block = $iat . ("\0" x (128 - length($iat)));
            $block   .= $ilt . ("\0" x (128 - length($ilt)));
            $block   .= $dir . ("\0" x 20);
            $block   .= "kernel32.dll\0";
            $block   .= ("\0" x (320 - length($block)));
            $block   .= $hints;

            return $block . ("\0" x (2048 - length($block)));
        }
    }

    class Brocken::Format::ELF : isa(Brocken::Format) {
        method _setup_layout($l, $t, $d, $a, $o) {
            $l->add_section('.text', $t, 5);
            $l->add_section('.data', $d, 6);
        }
        method write_bin($f, $text, $data, $arch, $os) {
            my $l = $self->layout;
            my $base = 0x400000;
            my $ehdr = pack('A4 C C C C C x7 S S L Q Q Q L S S S S S S', "\x7fELF", 2, 1, 1, 0, 0, 2, ($arch eq 'arm64' ? 183 : 62), 1, $base + $l->get('.text')->{rva}, 64, 0, 0, 64, 56, 2, 0, 0, 0);
            my $ph_t = pack('LL Q Q Q Q Q Q', 1, 5, $l->get('.text')->{off}, $base + $l->get('.text')->{rva}, $base + $l->get('.text')->{rva}, $l->get('.text')->{size}, $l->get('.text')->{size}, 0x1000);
            my $ph_d = pack('LL Q Q Q Q Q Q', 1, 6, $l->get('.data')->{off}, $base + $l->get('.data')->{rva}, $base + $l->get('.data')->{rva}, $l->get('.data')->{size}, $l->get('.data')->{size}, 0x1000);

            open my $fh, '>', $f or die $!; binmode $fh;
            print $fh $ehdr, $ph_t, $ph_d;

            for my $s ($l->sections) {
                my $payload = ($s->{name} eq '.text' ? $text : ($data || "\0"));

                # CRITICAL: Pad ELF segments to their exact declared size!
                if (length($payload) < $s->{size}) {
                    $payload .= "\0" x ($s->{size} - length($payload));
                }

                seek($fh, $s->{off}, 0);
                print $fh $payload;
            }

            close $fh; chmod 0755, $f; return $f;
        }
    }

    class Brocken::Format::MachO : isa(Brocken::Format) {
        method _setup_layout($l, $t, $d, $a, $o) {
            $l->add_section('__text', $t, 5);
            $l->add_section('__data', $d, 3);
        }
        method write_bin($f, $text, $data, $arch, $os) {
            my $l = $self->layout;
            my $hdr = pack('L L L L L L L L', 0xFEEDFACF, ($arch eq 'arm64' ? 0x0100000C : 0x01000007), 0, 2, 2, 312, 0x00200085, 0);

            open my $fh, '>', $f or die $!; binmode $fh;
            print $fh $hdr;

            for my $s ($l->sections) {
                my $payload = ($s->{name} eq '__text' ? $text : ($data || "\0"));
                if (length($payload) < $s->{size}) {
                    $payload .= "\0" x ($s->{size} - length($payload));
                }
                seek($fh, $s->{off}, 0);
                print $fh $payload;
            }

            close $fh; chmod 0755, $f; return $f;
        }
    }
}
1;
