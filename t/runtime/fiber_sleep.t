use v5.40;
use lib 'lib';
use Brocken::TestHelpers qw(test_brocken);
use Test2::V0;
subtest 'Basic Fiber Switch' => sub {
    plan skip_all => 'Fiber yield/switch runtime not fully implemented';
};
test_brocken(
    name   => 'Native Sleep',
    source => <<'BROCKEN',
        say "Sleep start";
        sleep 1;
        say "Sleep end";
BROCKEN
    expected => [ "Sleep start", "Sleep end" ]
);
done_testing;

