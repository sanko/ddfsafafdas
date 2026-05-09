package Brocken::Format {
    use v5.40;
    use feature 'class';
    no warnings 'experimental::class';

    class Brocken::Format {
        field $_layout     : reader(layout);
        field $debug_data  : reader = {};
        field $func_ranges : reader = [];
        method set_debug_data($d)   { $debug_data = $d; }
        method debug_section($name) { return $self->debug_data->{$name} // ''; }
        method set_func_ranges($r)  { $func_ranges = $r; }

        method rva_for($name) {
            return $self->layout->get($name)->{rva};
        }

        method pre_layout( $text_size, $data_size, $arch, $os, $debug = 0 ) {
            require Brocken::Format::Layout;
            $_layout = Brocken::Format::Layout->new( file_align => ( $os eq 'win64' ? 0x200 : 0x1000 ), section_align => 0x1000 );
            $self->_setup_layout( $_layout, $text_size, $data_size, $arch, $os, $debug );
            $_layout->calculate(0x1000);
        }
        method _setup_layout( $l, $t, $d, $a, $o, $dbg = 0 )    { die "Abstract" }
        method write_bin( $filename, $text, $data, $arch, $os ) { die "Abstract" }
        method import_rva($name)                                { die "Imports not supported by this format" }
    }
}
1;
__END__

=pod

=head1 NAME

Brocken::Format - Abstract base class for binary format writers

=head1 DESCRIPTION

Defines the interface for OS-specific binary format modules (PE, ELF, Mach-O). Provides shared layout management via
Brocken::Format::Layout.

Subclasses must implement C<_setup_layout>, C<write_bin>, and optionally C<import_rva>.

=head1 METHODS

=head2 rva_for($name)

Returns the RVA for a named section (delegates to Layout).

=head2 pre_layout($text_size, $data_size, $arch, $os)

Creates the Layout object and calls C<_setup_layout> to register sections.

=head2 write_bin($filename, $text, $data, $arch, $os)

Abstract. Writes the native executable to disk.

=cut
}
1;
