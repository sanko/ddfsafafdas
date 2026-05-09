use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
require Brocken::Format;
require Brocken::Format::PE;
use Brocken::TestHelpers qw(make_fake_funcs);
subtest 'set_func_ranges and reader' => sub {
    my $fmt   = Brocken::Format::PE->new;
    my $funcs = make_fake_funcs;
    $fmt->set_func_ranges($funcs);
    my $got = $fmt->func_ranges;
    is scalar(@$got),    scalar(@$funcs), 'same number of funcs';
    is $got->[0]{name},  'func_a',        'first func name';
    is $got->[1]{start}, 256,             'second func start';
};
subtest 'empty func_ranges' => sub {
    my $fmt = Brocken::Format::PE->new;
    my $got = $fmt->func_ranges;
    is scalar(@$got), 0, 'no funcs initially';
    $fmt->set_func_ranges( [] );
    $got = $fmt->func_ranges;
    is scalar(@$got), 0, 'empty after setting empty array';
};
subtest 'rva_for delegation' => sub {
    my $fmt = Brocken::Format::PE->new;
    $fmt->pre_layout( 4096, 4096, 'x64', 'win64', 0 );
    ok lives { $fmt->rva_for('.text') }, 'rva_for succeeds after pre_layout';
    is $fmt->rva_for('.text'), 0x1000, '.text RVA = 0x1000';
};
done_testing;
