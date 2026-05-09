package Brocken::Format::ELF {
    use v5.40;
    use feature 'class';
    no warnings 'experimental::class';
    #
    class Brocken::Format::ELF : isa(Brocken::Format) {

        method _setup_layout( $l, $t, $d, $a, $o ) {
            $l->add_section( '.text',  $t,   5 );    # RX
            $l->add_section( '.data',  $d,   6 );    # RW
            $l->add_section( '.debug', 4096, 0 );
        }

        method write_bin( $f, $text, $data, $arch, $os ) {
            my $l    = $self->layout;                # Access via reader
            my $base = 0x400000;
            my $ehdr = pack(
                'A4 C C C C C x7 S S L Q Q Q L S S S S S S',
                "\x7fELF", 2, 1, 1, 0, 0, 2, ( $arch eq 'arm64' ? 183 : 62 ),
                1,         $base + $l->get('.text')->{rva},
                64,        0, 0, 64, 56, 2, 0, 0, 0
            );
            my $ph_t = pack( 'LL Q Q Q Q Q Q',
                1, 5,
                $l->get('.text')->{off},
                $base + $l->get('.text')->{rva},
                $base + $l->get('.text')->{rva},
                $l->get('.text')->{size},
                $l->get('.text')->{size}, 0x1000 );
            my $ph_d = pack( 'LL Q Q Q Q Q Q',
                1, 6,
                $l->get('.data')->{off},
                $base + $l->get('.data')->{rva},
                $base + $l->get('.data')->{rva},
                $l->get('.data')->{size},
                $l->get('.data')->{size}, 0x1000 );
            open my $fh, '>', $f or die $!;
            binmode $fh;
            print $fh $ehdr, $ph_t, $ph_d;

            for my $s ( $l->sections ) {
                my $dd      = $self->debug_data;
                my $payload = $s->{name} eq '.text' ? $text : ( $s->{name} eq '.debug' ? ( $dd || "\0" ) : ( $data || "\0" ) );
                $payload .= ( "\0" x ( $s->{size} - length($payload) ) ) if length($payload) < $s->{size};
                seek( $fh, $s->{off}, 0 );
                print $fh $payload;
            }
            close $fh;
            chmod 0755, $f;
            return $f;
        }
    }
}
1;
