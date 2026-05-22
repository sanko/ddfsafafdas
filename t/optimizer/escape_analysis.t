use v5.40;
use lib 'lib', '../../lib';
use Brocken::TestHelpers qw(test_brocken);
use Test2::V0;
test_brocken(
    name   => 'Stack Allocation via Escape Analysis',
    source => q{
        # This array is completely local to this block.
        # Escape Analysis will detect this, bypass the heap nursery,
        # and allocate it on the physical stack for 0-cost execution!
        my Any $a = [10, 20, 30];
        say "Array elements: " . $a[0] . " " . $a[1] . " " . $a[2];
    },
    expected => ["Array elements: 10 20 30"]
);
done_testing;
