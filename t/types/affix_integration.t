use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
use Brocken::Type;
subtest 'from_affix with string type names' => sub {
    my $t = Brocken::Type->from_affix('Int');
    ok $t->isa('Brocken::Type'), 'Int from affix string isa Type';
    is $t->{size}, 8, 'Int size = 8';
};
subtest 'from_affix with various string names' => sub {
    my $t1 = Brocken::Type->from_affix('Str');
    ok $t1->isa('Brocken::Type'), 'Str from affix string isa Type';
    my $t2 = Brocken::Type->from_affix('Float');
    ok $t2->isa('Brocken::Type'), 'Float from affix string isa Type';
};
done_testing;
