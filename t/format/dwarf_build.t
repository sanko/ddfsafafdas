use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
require Brocken::Format::DWARF;
use Brocken::TestHelpers qw(make_fake_funcs make_source_locs);
my $TEXT_BASE = 0x401000;
my $EH_BASE   = 0x405000;
my $CTX_WIN64 = 64;
my $CTX_LINUX = 48;
subtest 'build_debug_line' => sub {
    my $sls  = make_source_locs;
    my $dw   = Brocken::Format::DWARF->new( source_locs => $sls, text_base => $TEXT_BASE );
    my $data = $dw->build_debug_line;
    ok length($data) > 20, 'debug_line has content';
    my ($unit_len) = unpack( 'L<', $data );
    ok $unit_len > 0, 'unit length is positive';
    my ($version) = unpack( 'x4 S<', $data );
    is $version, 2, 'DWARF version 2';
};
subtest 'build_debug_abbrev' => sub {
    my $dw   = Brocken::Format::DWARF->new( source_locs => [], text_base => $TEXT_BASE );
    my $data = $dw->build_debug_abbrev;
    ok length($data) > 10,                     'abbrev table has content';
    ok $data =~ m{\x00},                       'ends with null terminator';
    ok index( $data, pack( 'C', 0x11 ) ) >= 0, 'contains DW_TAG_compile_unit';
};
subtest 'build_debug_info' => sub {
    my $funcs = make_fake_funcs;
    my $dw    = Brocken::Format::DWARF->new( source_locs => [], text_base => $TEXT_BASE, func_ranges => $funcs, context_size => $CTX_WIN64 );
    my $data  = $dw->build_debug_info;
    ok length($data) > 30, 'debug_info has content';
    my ($cu_len) = unpack( 'L<', $data );
    ok $cu_len > 0, 'CU length positive';
    my ($version) = unpack( 'x4 S<', $data );
    is $version, 2, 'DWARF version 2';
};
todo 'DWARF .debug_frame CIE length encoding needs fixing' => sub {
    subtest 'build_debug_frame' => sub {
        my $funcs = make_fake_funcs;
        my $dw    = Brocken::Format::DWARF->new( source_locs => [], text_base => $TEXT_BASE, func_ranges => $funcs, context_size => $CTX_WIN64 );
        my $data  = $dw->build_debug_frame;
        ok length($data) > 40, 'debug_frame has content';
        my ($cie_len) = unpack( 'L<', $data );
        is $cie_len, length($data) - 4 - 4 - 4 - 4, 'CIE + FDEs length matches' or diag "CIE=$cie_len total=" . length($data);
        my ($cie_id) = unpack( 'x4 L<', $data );
        is $cie_id, 0xFFFFFFFF, 'CIE id = -1 (DWARF3)';
        my $fde_count = 0;
        my $pos       = 4 + $cie_len;

        while ( $pos < length($data) ) {
            my ($fde_len) = unpack( "x${pos} L<", $data );
            last if $fde_len == 0;
            $fde_count++;
            $pos += 4 + $fde_len;
        }
        is $fde_count, scalar(@$funcs), "FDE count matches func_ranges";
    };
};
todo 'DWARF .eh_frame FDE encoding offset calculation needs fixing' => sub {
    subtest 'build_eh_frame' => sub {
        my $funcs = make_fake_funcs;
        my $dw    = Brocken::Format::DWARF->new(
            source_locs   => [],
            text_base     => $TEXT_BASE,
            func_ranges   => $funcs,
            context_size  => $CTX_WIN64,
            eh_frame_base => $EH_BASE
        );
        my $data = $dw->build_eh_frame;
        ok length($data) > 0, 'eh_frame has content';
        my ($cie_len) = unpack( 'L<', $data );
        ok $cie_len > 0, 'CIE length positive';
        my ($cie_id) = unpack( 'x4 L<', $data );
        is $cie_id, 0, 'CIE id = 0 (eh_frame)';
        my $body = substr( $data, 8, $cie_len );
        ok index( $body, "zR\0" ) >= 0, 'CIE augmentation is "zR"';
        my ($fde_enc) = unpack( "x" . ( length($body) - 4 ) . "C", $body );
        is $fde_enc, 0x1B, 'FDE encoding = pcrel|sdata4 (0x1B)';
        my $fde_count = 0;
        my $pos       = 4 + $cie_len;

        while ( $pos < length($data) ) {
            my ($fde_len) = unpack( "x${pos} L<", $data );
            last if $fde_len == 0;
            $fde_count++;
            $pos += 4 + $fde_len;
        }
        is $fde_count, scalar(@$funcs), 'FDE count matches func_ranges';
    };
};
subtest 'build_debug_aranges' => sub {
    my $funcs = make_fake_funcs;
    my $dw    = Brocken::Format::DWARF->new( source_locs => [], text_base => $TEXT_BASE, func_ranges => $funcs );
    my $data  = $dw->build_debug_aranges;
    ok length($data) > 20, 'aranges has content';
    my ($unit_len) = unpack( 'L<', $data );
    ok $unit_len > 0, 'unit length positive';
};
subtest 'build_all' => sub {
    my $funcs = make_fake_funcs;
    my $sls   = make_source_locs;
    my $dw    = Brocken::Format::DWARF->new(
        source_locs   => $sls,
        text_base     => $TEXT_BASE,
        func_ranges   => $funcs,
        context_size  => $CTX_WIN64,
        eh_frame_base => $EH_BASE
    );
    my $sections = $dw->build_all;
    ok exists $sections->{'.debug_line'},     'has .debug_line';
    ok exists $sections->{'.debug_info'},     'has .debug_info';
    ok exists $sections->{'.debug_abbrev'},   'has .debug_abbrev';
    ok exists $sections->{'.debug_frame'},    'has .debug_frame';
    ok exists $sections->{'.debug_aranges'},  'has .debug_aranges';
    ok exists $sections->{'.debug_pubnames'}, 'has .debug_pubnames';
    ok exists $sections->{'.eh_frame'},       'has .eh_frame';

    for my $k ( keys %$sections ) {
        ok length( $sections->{$k} ) > 0, "$k is non-empty";
    }
};
subtest 'LEB128 encoding' => sub {
    my $dw = Brocken::Format::DWARF->new( source_locs => [], text_base => $TEXT_BASE );
    is unpack( 'H*', $dw->_uleb(0) ),   '00',   'ULEB(0)';
    is unpack( 'H*', $dw->_uleb(1) ),   '01',   'ULEB(1)';
    is unpack( 'H*', $dw->_uleb(127) ), '7f',   'ULEB(127)';
    is unpack( 'H*', $dw->_uleb(128) ), '8001', 'ULEB(128)';
    is unpack( 'H*', $dw->_sleb(0) ),   '00',   'SLEB(0)';
    is unpack( 'H*', $dw->_sleb(-1) ),  '7f',   'SLEB(-1)';
    is unpack( 'H*', $dw->_sleb(-8) ),  '78',   'SLEB(-8)';
};
done_testing;
