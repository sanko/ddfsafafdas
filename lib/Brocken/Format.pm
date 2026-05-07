package Brocken::Format {
    use v5.40;
    use feature 'class';

    no warnings 'experimental::class';
    class Brocken::Format {
        field $_layout :reader(layout); # Explicitly name the reader 'layout'

        method rva_for($name) {
            return $self->layout->get($name)->{rva};
        }

        method pre_layout($text_size, $data_size, $arch, $os) {
            require Brocken::Format::Layout;
            $_layout = Brocken::Format::Layout->new(
                file_align    => ($os eq 'win64' ? 0x200 : 0x1000),
                section_align => 0x1000
            );
            $self->_setup_layout($_layout, $text_size, $data_size, $arch, $os);
            $_layout->calculate(0x1000);
        }

        method _setup_layout($l, $t, $d, $a, $o) { die "Abstract" }
        method write_bin($filename, $text, $data, $arch, $os) { die "Abstract" }
        method import_rva($name) { die "Imports not supported by this format" }
    }
}
1;
