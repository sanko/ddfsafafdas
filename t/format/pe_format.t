use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
require Brocken::Format::PE;
require Brocken::Format::Layout;
require Brocken::Format::DWARF;
use Brocken::TestHelpers qw(make_fake_funcs make_source_locs);
subtest 'setup_layout with debug=0' => sub {
    my $pe = Brocken::Format::PE->new;
    my $l  = Brocken::Format::Layout->new( file_align => 0x200, section_align => 0x1000 );
    $pe->_setup_layout( $l, 4096, 4096, 'x64', 'win64', 0 );
    my @names = map { $_->{name} } $l->sections;
    is scalar(@names), 5,        '5 sections (text, data, idata, pdata, xdata)';
    is $names[0],      '.text',  'first is .text';
    is $names[1],      '.data',  'second is .data';
    is $names[2],      '.idata', 'third is .idata';
    is $names[3],      '.pdata', 'fourth is .pdata (required by win64)';
    is $names[4],      '.xdata', 'fifth is .xdata (required by win64)';
};
subtest 'setup_layout with debug=1 win64' => sub {
    my $pe = Brocken::Format::PE->new;
    my $l  = Brocken::Format::Layout->new( file_align => 0x200, section_align => 0x1000 );
    $pe->_setup_layout( $l, 4096, 4096, 'x64', 'win64', 1 );
    my @names = map { $_->{name} } $l->sections;
    ok grep( /^\.pdata$/,      @names ), 'has .pdata with win64';
    ok grep( /^\.xdata$/,      @names ), 'has .xdata with win64';
    ok grep( /^\.debug_line$/, @names ), 'has .debug_line';
};
subtest 'setup_layout with debug=1 non-win64' => sub {
    my $pe = Brocken::Format::PE->new;
    my $l  = Brocken::Format::Layout->new( file_align => 0x200, section_align => 0x1000 );
    $pe->_setup_layout( $l, 4096, 4096, 'x64', 'linux', 1 );
    my @names = map { $_->{name} } $l->sections;
    ok !grep( /^\.pdata$/, @names ), 'no .pdata on linux';
    ok !grep( /^\.xdata$/, @names ), 'no .xdata on linux';
};
subtest 'image_base' => sub {
    my $pe = Brocken::Format::PE->new;
    is $pe->image_base, 0x140000000, 'PE image base = 0x140000000';
};
todo 'import system not yet wired up' => sub {
    subtest 'import_rva' => sub {
        my $pe = Brocken::Format::PE->new;
        ok lives { $pe->import_rva('ExitProcess') }, 'ExitProcess is known';
        ok lives { $pe->import_rva('WriteFile') },   'WriteFile is known';
        ok dies { $pe->import_rva('Unknown') }, 'unknown import dies';
    };
};
subtest 'pre_layout' => sub {
    my $pe = Brocken::Format::PE->new;
    $pe->pre_layout( 4096, 4096, 'x64', 'win64', 2 );
    my $l = $pe->layout;
    ok defined $l,                   'layout exists';
    ok $l->get('.text')->{rva} > 0,  '.text has RVA';
    ok $l->get('.pdata')->{rva} > 0, '.pdata has RVA' or diag 'pdata not found (no win64 in setup_layout?)';
};
subtest 'debug_data flow' => sub {
    my $pe       = Brocken::Format::PE->new;
    my $funcs    = make_fake_funcs;
    my $sls      = make_source_locs;
    my $dw       = Brocken::Format::DWARF->new( source_locs => $sls, text_base => 0x140001000, func_ranges => $funcs, context_size => 64 );
    my $sections = $dw->build_all;
    $pe->set_debug_data($sections);
    ok length( $pe->debug_section('.debug_line') ) > 0,  'debug_line accessible';
    ok length( $pe->debug_section('.debug_frame') ) > 0, 'debug_frame accessible';
    is $pe->debug_section('.nope'), '', 'unknown section returns empty string';
};
done_testing;
