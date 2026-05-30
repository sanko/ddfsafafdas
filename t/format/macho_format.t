use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
require Brocken::Target::Format::MachO;
subtest 'MachO instantiation' => sub {
    my $f = Brocken::Target::Format::MachO->new;
    ok $f->isa('Brocken::Target::Format::MachO'), 'isa MachO';
    ok $f->isa('Brocken::Format'),                'isa Format base';
    is $f->type, 'exe', 'default type is exe';
};
subtest 'MachO image_base' => sub {
    my $f = Brocken::Target::Format::MachO->new;
    is $f->image_base, 0x100000000, 'MachO image base = 0x100000000';
};
subtest 'MachO pre_layout without debug' => sub {
    my $f = Brocken::Target::Format::MachO->new;
    $f->pre_layout( 4096, 4096, 'x64', 'macos', 0 );
    my @sections = $f->layout->sections;
    is scalar(@sections),    4,           '4 sections without debug';
    is $sections[0]->{name}, '.text',     'first is .text';
    is $sections[1]->{name}, '.data',     'second is .data';
    is $sections[2]->{name}, '.got',      'third is .got';
    is $sections[3]->{name}, '.linkedit', 'fourth is .linkedit';
};
subtest 'MachO pre_layout as shared library' => sub {
    my $f = Brocken::Target::Format::MachO->new( type => 'shared' );
    $f->pre_layout( 4096, 4096, 'arm64', 'macos', 0 );
    my @names = map { $_->{name} } $f->layout->sections;
    ok grep( /^\.linkedit$/, @names ), 'shared lib has .linkedit';
};
subtest 'MachO pre_layout with debug' => sub {
    my $f = Brocken::Target::Format::MachO->new;
    $f->pre_layout( 4096, 4096, 'x64', 'macos', 1 );
    my @names = map { $_->{name} } $f->layout->sections;
    ok grep( /^\.debug_line$/,  @names ), 'has .debug_line';
    ok grep( /^\.debug_info$/,  @names ), 'has .debug_info';
    ok grep( /^\.debug_frame$/, @names ), 'has .debug_frame';
};
subtest 'MachO pre_layout sets RVAs' => sub {
    my $f = Brocken::Target::Format::MachO->new;
    $f->pre_layout( 64, 64, 'x64', 'macos', 0 );
    ok $f->layout->get('.text')->{rva} > 0, '.text RVA is positive';
    ok $f->layout->get('.data')->{rva} > 0, '.data RVA is positive';
};
subtest 'MachO write_bin exe' => sub {
    my $f = Brocken::Target::Format::MachO->new;
    $f->pre_layout( 64, 64, 'x64', 'macos', 0 );
    $f->set_func_ranges( [] );
    $f->set_labels( {} );
    my $out = $f->write_bin( 'test_macho', "\x90" x 64, '', 'x64', 'macos', 'exe' );
    ok length($out) > 0, 'MachO exe write_bin produces output';
};
subtest 'MachO write_bin shared library' => sub {
    my $f = Brocken::Target::Format::MachO->new( type => 'shared' );
    $f->pre_layout( 64, 64, 'arm64', 'macos', 0 );
    $f->set_func_ranges( [] );
    $f->set_labels( {} );
    $f->set_exported_funcs( ['test_func'] );
    my $out = $f->write_bin( 'test_dylib', "\x90" x 64, '', 'arm64', 'macos', 'shared' );
    ok length($out) > 0, 'MachO shared lib write_bin produces output';
};
done_testing;
