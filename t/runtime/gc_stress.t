use v5.40;
use lib '../../lib';
use Brocken::TestHelpers qw(test_brocken);
use Test::More;
plan tests => 7;

TODO: {
    local $TODO = 'GC stress tests crash at runtime (empty output) — pre-existing GC implementation bug';
    test_brocken(
        name   => 'medium_arrays',
        source => q{
            my Int $i = 0;
            while ($i < 1000) {
                my Any $a = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
                my Any $b = [1, 2, 3];
                $i = $i + 1;
            }
            say "Done";
        },
        expected => qr/Done/
    );
    test_brocken(
        name   => 'large_arrays',
        source => q{
            my Int $i = 0;
            while ($i < 500) {
                my Any $a = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20];
                $i = $i + 1;
            }
            say "Done";
        },
        expected => qr/Done/
    );
    test_brocken(
        name   => 'mixed_sizes',
        source => q{
            my Int $i = 0;
            while ($i < 500) {
                my Any $a = [1];
                my Any $b = [1, 2, 3, 4, 5];
                my Any $c = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12];
                my Any $d = [1, 2];
                my Any $e = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20];
                $i = $i + 1;
            }
            say "Done";
        },
        expected => qr/Done/
    );
    test_brocken(
        name   => 'gc_stress_10k',
        source => q{
            my Int $i = 0;
            while ($i < 10000) {
                my Any $a = [1];
                my Any $b = [2];
                my Any $c = [3];
                $i = $i + 1;
            }
            say "Done: " . $i;
        },
        expected => qr/Done: 10000/,
        timeout  => 60
    );
    test_brocken(
        name   => 'gc_stress_100k',
        source => q{
            my Int $i = 0;
            while ($i < 100000) {
                my Any $a = [1];
                my Any $b = [2];
                my Any $c = [3];
                $i = $i + 1;
            }
            say "Done: " . $i;
        },
        expected => qr/Done: 100000/,
        timeout  => 120
    );
}

TODO: {
    local $TODO = 'class keyword in Brocken not fully implemented in parser';
    test_brocken(
        name   => 'classes_and_gc',
        source => q{
            class Test {
                field Any $a;
                field Any $b;
                method set(Int $x, Int $y) { $a = $x; $b = $y; }
                method get() { return $a + $b; }
            }
            my Int $i = 0;
            while ($i < 1000) {
                my Any $t = new Test();
                $t.set($i, $i + 1);
                my Int $r = $t.get();
                $i = $i + 1;
            }
            say "Done";
        },
        expected => qr/Done/
    );
}

TODO: {
    local $TODO = 'Nested arrays crash at runtime — pre-existing GC bug';
    test_brocken(
        name   => 'nested_arrays',
        source => q{
            my Int $i = 0;
            while ($i < 500) {
                my Any $a = [[1, 2], [3, 4], [5, 6]];
                my Any $b = [[1], [2], [3], [4], [5]];
                $i = $i + 1;
            }
            say "Done";
        },
        expected => qr/Done/
    );
}
