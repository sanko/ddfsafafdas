use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
require Brocken::Target::Format::ELF;
require Brocken::Target::Format::Layout;
require Brocken::Target::Format::DWARF;
use Brocken::TestHelpers qw(make_fake_funcs make_source_locs);
subtest 'setup_layout with debug=0' => sub {
    my $elf = Brocken::Target::Format::ELF->new;
    my $l   = Brocken::Target::Format::Layout->new( file_align => 0x1000, section_align => 0x1000 );
    $elf->_setup_layout( $l, 4096, 4096, 'x64', 'linux', 0 );
    my @names = map { $_->{name} } $l->sections;
    is scalar(@names), 9,       '9 sections without debug';
    is $names[0],      '.text', 'first is .text';
    is $names[1],      '.data', 'second is .data';
};
subtest 'setup_layout with debug=1' => sub {
    my $elf = Brocken::Target::Format::ELF->new;
    my $l   = Brocken::Target::Format::Layout->new( file_align => 0x1000, section_align => 0x1000 );
    $elf->_setup_layout( $l, 4096, 4096, 'x64', 'linux', 1 );
    my @names = map { $_->{name} } $l->sections;
    ok grep( /^\.debug_line$/,   @names ), 'has .debug_line';
    ok grep( /^\.debug_info$/,   @names ), 'has .debug_info';
    ok grep( /^\.debug_abbrev$/, @names ), 'has .debug_abbrev';
    ok grep( /^\.debug_frame$/,  @names ), 'has .debug_frame';
    ok grep( /^\.eh_frame$/,     @names ), 'has .eh_frame';
};
subtest 'image_base' => sub {
    my $elf = Brocken::Target::Format::ELF->new;
    is $elf->image_base, 0x400000, 'ELF image base = 0x400000';
};
subtest 'pre_layout' => sub {
    my $elf = Brocken::Target::Format::ELF->new;
    $elf->pre_layout( 4096, 4096, 'x64', 'linux', 2 );
    my $l = $elf->layout;
    ok defined $l, 'layout exists';
    is $l->get('.text')->{rva}, 0x1000, '.text RVA = 0x1000';
    ok $l->get('.eh_frame')->{rva} > 0, '.eh_frame has RVA';
};
subtest 'debug_data with eh_frame' => sub {
    my $elf = Brocken::Target::Format::ELF->new;
    $elf->pre_layout( 4096, 4096, 'x64', 'linux', 2 );
    my $text_base = $elf->image_base + $elf->rva_for('.text');
    my $eh_base   = $elf->image_base + $elf->rva_for('.eh_frame');
    my $funcs     = make_fake_funcs;
    my $sls       = make_source_locs;
    my $dw        = Brocken::Target::Format::DWARF->new(
        source_locs   => $sls,
        text_base     => $text_base,
        eh_frame_base => $eh_base,
        func_ranges   => $funcs,
        context_size  => 48
    );
    my $sections = $dw->build_all;
    $elf->set_debug_data($sections);
    ok length( $elf->debug_section('.debug_line') ) > 0,  'debug_line accessible';
    ok length( $elf->debug_section('.debug_frame') ) > 0, 'debug_frame accessible';
    ok length( $elf->debug_section('.eh_frame') ) > 0,    'eh_frame accessible';
    my $ef = $elf->debug_section('.eh_frame');
    my ($cie_id) = unpack( 'x4 L<', $ef );
    is $cie_id, 0, '.eh_frame CIE id = 0';
};
done_testing;
