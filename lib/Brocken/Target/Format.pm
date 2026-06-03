use v5.40;
use feature 'class';
no warnings 'experimental::class';

class Brocken::Target::Format {
    field $_layout        : reader(layout);
    field $type           : param : reader = 'exe';
    field $debug_data     : reader = {};
    field $func_ranges    : reader = [];
    field $labels         : reader = {};
    field $exported_funcs : reader = [];
    field $preserved_regs : reader = [];
    field $frame_size     : reader = 0;
    field $timestamp      : reader = undef;
    #
    method set_preserved_regs($r) { $preserved_regs = $r; }
    method set_frame_size($s)     { $frame_size     = $s; }
    method set_timestamp($t)      { $timestamp      = $t; }

    # Default to the current time when not explicitly set. Pass 0 to
    # write a deterministic build (e.g. for reproducible-build tests).
    method effective_timestamp() { $timestamp // time() }
    method set_debug_data($d)    { $debug_data = $d; }
    method debug_section($name)  { return $self->debug_data->{$name} // ''; }
    method set_func_ranges($r)   { $func_ranges = $r; }
    method set_labels($l)        { $labels      = $l; }

    # shared lib
    method set_exported_funcs($f) { $exported_funcs = $f; }
    #
    method rva_for($name) {
        return $self->layout->get($name)->{rva};
    }
    method image_base() { return 0; }

    method pre_layout( $text_size, $data_size, $arch, $os, $debug = 0 ) {
        require Brocken::Target::Format::Layout;
        my $fa = $os eq 'macos' ? 0x4000 : ( $os eq 'win64' ? 0x200 : 0x1000 );
        my $sa = $os eq 'macos' ? 0x4000 : 0x1000;
        $_layout = Brocken::Target::Format::Layout->new( file_align => $fa, section_align => $sa );
        $self->_setup_layout( $_layout, $text_size, $data_size, $arch, $os, $debug );
        $_layout->calculate( $os eq 'macos' ? 0x4000 : 0x1000 );
    }
    method _setup_layout( $l, $t, $d, $a, $o, $dbg = 0 )           { die "Abstract" }
    method write_bin( $filename, $text, $data, $arch, $os, $type ) { die "Abstract" }
    method import_rva($name)                                       { die "Imports not supported by this format" }
}
1;
