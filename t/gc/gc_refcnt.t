use v5.40;
use lib 'lib';
use Brocken::TestHelpers qw(test_brocken);
use Test2::V0;
test_brocken(
    name   => 'Manual and Automatic RC Tracking',
    source => q{
        my Any $a = [1, 2, 3];
        say "Initial RC: " . refcount($a);

        retain($a);
        say "After Retain: " . refcount($a);

        retain($a);
        say "After 2nd Retain: " . refcount($a);

        release($a);
        say "After 1st Release: " . refcount($a);

        my Any $arr = [undef];
        $arr[0] = $a; # Trigger compiler write barrier!
        say "After Write Barrier: " . refcount($a);

        $arr[0] = undef; # Overwrite array slot to trigger decrement write barrier
        say "After Clearing Array: " . refcount($a);
    },
    expected =>
        [ "Initial RC: 0", "After Retain: 1", "After 2nd Retain: 2", "After 1st Release: 1", "After Write Barrier: 2", "After Clearing Array: 1" ]
);
done_testing;
