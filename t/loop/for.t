use v5.40;
use lib 'lib';
use Brocken::TestHelpers qw(test_brocken);
use Test2::V0;
test_brocken(
    name   => 'Zero-Allocation Range Loops',
    source => q{
        my Int $sum = 0;
        for my $i (1 .. 1000000) {
            $sum = $sum + 1;
        }
        say "Fast Range Sum: " . $sum;
    },
    expected => ["Fast Range Sum: 1000000"]
);
test_brocken(
    name   => 'List Destructuring (2 Elements)',
    source => q{
        my Any $a = ["Apple", "Orange", "Banana", "Grape"];
        for my ($fruit1, $fruit2) ($a) {
            say "Pair: " . $fruit1 . " and " . $fruit2;
        }
    },
    expected => [ "Pair: Apple and Orange", "Pair: Banana and Grape", ]
);
test_brocken(
    name   => 'List Destructuring (Out Of Bounds Defaults to Undef)',
    source => q{
        my Any $a = [1, 2, 3];
        for my ($x, $y) ($a) {
            say "Vals: " . $x . " " . $y;
        }
    },
    expected => [ "Vals: 1 2", "Vals: 3 undef", ]
);
test_brocken(
    name   => 'Dynamic Hash Iteration',
    source => q{
        my Any $h = { "name" => "Brocken", "type" => "Compiler" };

        my Int $count = 0;
        # Order is not guaranteed, so we just check iteration counts
        for my ($k, $v) ($h) {
            $count = $count + 1;
        }
        say "Hash elements: " . $count;
    },
    expected => ["Hash elements: 2"]
);
done_testing;

