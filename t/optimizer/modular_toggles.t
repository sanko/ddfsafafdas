use v5.40;
use lib 'lib', '../../lib';
use Brocken::TestHelpers qw(test_brocken);
use Test2::V0;

# Test modular toggles for optimizations
test_brocken(
    name   => 'Escape Analysis Enabled (Default)',
    source => q{
        my Any $a = [10, 20, 30];
        say "Value: " . $a[0];
    },
    expected => ["Value: 10"]
);

test_brocken(
    name   => 'Escape Analysis Disabled',
    source => q{
        my Any $a = [10, 20, 30];
        say "Value: " . $a[0];
    },
    opts => { optimizations => { escape => 0 } },
    expected => ["Value: 10"]
);

# Test DCE toggle
test_brocken(
    name   => 'Dead Code Elimination Enabled',
    source => q{
        my Int $unused = 42;
        say "Alive";
    },
    expected => ["Alive"]
);

test_brocken(
    name   => 'Dead Code Elimination Disabled',
    source => q{
        my Int $unused = 42;
        say "Alive";
    },
    opts => { optimizations => { dce => 0 } },
    expected => ["Alive"]
);

done_testing;
