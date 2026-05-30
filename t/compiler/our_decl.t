use v5.40;
use utf8;
use feature 'class';
no warnings 'experimental::class', 'portable';
use lib 'lib', '../../lib';
use Test2::V0;
use Brocken::TestHelpers qw(test_brocken);

# Test 1: our with type and initializer
{
    my ( $out, $err ) = test_brocken( source => <<'BROCKEN' );
our Int $x = 42;
say $x;
BROCKEN
    ok !$err, 'our Int $x = 42 compiled' or diag "Error: $err";
    is $out, '42', 'our Int $x = 42 prints 42';
}

# Test 2: our without type, with initializer
{
    my ( $out, $err ) = test_brocken( source => <<'BROCKEN' );
our $x = 99;
say $x;
BROCKEN
    ok !$err, 'our $x = 99 compiled' or diag "Error: $err";
    is $out, '99', 'our $x = 99 prints 99';
}

# Test 3: our with type, no initializer (assign after decl)
{
    my ( $out, $err ) = test_brocken( source => <<'BROCKEN' );
our Int $x;
$x = 42;
say $x;
BROCKEN
    ok !$err, 'our Int $x (no init) compiled' or diag "Error: $err";
    is $out, '42', 'our Int $x assigned after decl = 42';
}

# Test 4: our without type or initializer
{
    my ( $out, $err ) = test_brocken( source => <<'BROCKEN' );
our $x;
$x = 7;
say $x;
BROCKEN
    ok !$err, 'our $x (no init) compiled' or diag "Error: $err";
    is $out, '7', 'our $x assigned then prints 7';
}

# Test 5: our accessed across subroutines
{
    my ( $out, $err ) = test_brocken( source => <<'BROCKEN' );
our Int $counter = 0;
sub inc() {
    $counter = $counter + 1;
}
inc();
inc();
inc();
say $counter;
BROCKEN
    ok !$err, 'our cross-sub access compiled' or diag "Error: $err";
    is $out, '3', 'our $counter incremented across sub calls = 3';
}

# Test 6: our accessed inside a block scope
{
    my ( $out, $err ) = test_brocken( source => <<'BROCKEN' );
our Int $x = 10;
{
    say $x;
    $x = 20;
}
say $x;
BROCKEN
    ok !$err, 'our inside block compiled' or diag "Error: $err";
    is $out, "10\n20", 'our $x accessible inside block and modified';
}

# Test 7: multiple our declarations
{
    my ( $out, $err ) = test_brocken( source => <<'BROCKEN' );
our Int $a = 1;
our Int $b = 2;
our Int $c = 3;
say $a + $b + $c;
BROCKEN
    ok !$err, 'multiple our vars compiled' or diag "Error: $err";
    is $out, '6', 'multiple our vars sum = 6';
}
done_testing;

