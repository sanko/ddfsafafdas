use v5.40;
use lib 'lib';
use Brocken::TestHelpers qw(test_brocken);
use Test::More;
plan tests => 2;
test_brocken(
    name   => 'Basic Fiber Switch',
    source => <<'BROCKEN',
        my Fiber $f = sub (Any $val) {
            say "Fiber start";
            yield 123;
            say "Fiber end";
            return 456;
        };
        say "Main switch 1";
        my Any $r1 = $f.switch(0);
        say "Main back 1: " + $r1;
        say "Main switch 2";
        my Any $r2 = $f.switch(0);
        say "Main back 2: " + $r2;
BROCKEN
    expected => [ "Main switch 1", "Fiber start", "Main back 1: 123", "Main switch 2", "Fiber end", "Main back 2: 456", ]
);
test_brocken(
    name   => 'Native Sleep',
    source => <<'BROCKEN',
        say "Sleep start";
        sleep 1;
        say "Sleep end";
BROCKEN
    expected => [ "Sleep start", "Sleep end", ]
);
