package Brocken::Format::PE {
    use v5.40;
    use feature 'class';
        no warnings 'portable';

    no warnings 'experimental::class';

    class Brocken::Format::PE :isa(Brocken::Format) {
        our %IMPORTS = (
            ExitProcess                 => 0,
            GetStdHandle                => 8,
            WriteFile                   => 16,
            VirtualAlloc                => 24,
            SetConsoleOutputCP          => 32,
            AddVectoredExceptionHandler => 40
        );

        method import_rva($n) {
            return $self->rva_for('.idata') + ($IMPORTS{$n} // die "Unknown PE import: $n");
        }

        method _setup_layout($l, $t, $d, $a, $o) {
            $l->add_section( '.text',  $t,                    0x60000020 );
            $l->add_section( '.data',  ( $d > 0 ? $d : 512 ), 0xC0000040 );
            $l->add_section( '.idata', 2048,                  0xC0000040 );
        }

        method write_bin($filename, $text, $data, $arch, $os) {
            my $l          = $self->layout; # Access via reader
            my $idata_rva  = $l->get('.idata')->{rva};
            my $idata_raw  = $self->_build_idata_raw($idata_rva);
            my $image_size = $l->calculate(0x1000);
            my $m_type     = ($arch eq 'arm64' ? 0xAA64 : 0x8664);

            open my $fh, '>', $filename or die $!;
            binmode $fh;

            print $fh pack('S< x58 L<', 0x5A4D, 0x80), pack('a64', "Brocken AOT\n\$"), pack('L<', 0x4550);
            print $fh pack('S< S< L< L< L< S< S<', $m_type, scalar($l->sections), time(), 0, 0, 240, 0x0022);

            # Optional Header (The Q< handles the 64-bit image base 0x140000000)
            print $fh pack(
                'S< C C L< L< L< L< L< Q< L< L< S< S< S< S< S< S< L< L< L< L< S< S< Q< Q< Q< Q< L< L<',
                0x20B, 14, 0, $l->get('.text')->{size}, $l->get('.data')->{size} + length($idata_raw), 0,
                $l->get('.text')->{rva}, $l->get('.text')->{rva},
                0x140000000, # ImageBase
                0x1000, 0x200, 6, 0, 0, 0, 6, 0, 0,
                $image_size, $l->header_size, 0, 3, 0x8140, 0x100000, 0x1000, 0x100000, 0x1000, 0, 16
            );

            print $fh pack('L< L<', 0, 0), pack('L< L<', $idata_rva + 256, 40);
            print $fh (pack('L< L<', 0, 0) x 10);
            print $fh pack('L< L<', $idata_rva, 64), (pack('L< L<', 0, 0) x 3);

            for my $s ($l->sections) {
                my $file_size = ($s->{size} + 0x1FF) & ~0x1FF;
                print $fh pack('a8 L< L< L< L< L< L< S< S< L<', $s->{name}, $s->{size}, $s->{rva}, $file_size, $s->{off}, 0, 0, 0, 0, $s->{flags});
            }
            print $fh ("\0" x ($l->header_size - tell($fh)));

            for my $s ($l->sections) {
                my $payload = $s->{name} eq '.text' ? $text : ($s->{name} eq '.idata' ? $idata_raw : ($data || "\0"));
                my $file_size = ($s->{size} + 0x1FF) & ~0x1FF;
                $payload .= "\0" x ($file_size - length($payload)) if length($payload) < $file_size;
                $payload = substr($payload, 0, $file_size);
                seek($fh, $s->{off}, 0);
                print $fh $payload;
            }
            close $fh;
            return $filename;
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
            my $dir = pack('L< L< L< L< L<', $base_rva + 128, 0, 0, $base_rva + 296, $base_rva);
            my $block = $iat . ("\0" x (128 - length($iat))) . $ilt . ("\0" x (128 - length($ilt))) . $dir . ("\0" x 20);
            $block .= "kernel32.dll\0";
            $block .= ("\0" x (320 - length($block))) . $hints;
            return $block . ("\0" x (2048 - length($block)));
        }
    }
}
1;
