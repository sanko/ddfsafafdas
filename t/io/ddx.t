use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
use Brocken::TestHelpers qw(test_brocken);
my $has_native = 0;
{
    my ( $out, $err ) = test_brocken( source => 'say 42;' );
    $has_native = 1 if defined $out && $out eq '42';
}
if ( !$has_native ) {
    diag "Native compilation not available, skipping runtime tests";
    done_testing;
    exit 0;
}

# --- dd tests (return value, captured via say) ---
subtest 'dd basic integer' => sub {
    my ( $out, $err ) = test_brocken( source => 'say dd(42);' );
    ok !$err, "no error" or diag "err=$err";
    is $out, '42', 'dd(42) returns "42"';
};
subtest 'dd basic string' => sub {
    my ( $out, $err ) = test_brocken( source => 'say dd("hello");' );
    ok !$err, "no error" or diag "err=$err";
    is $out, '"hello"', 'dd("hello") returns "\"hello\""';
};
subtest 'dd variable integer' => sub {
    my ( $out, $err ) = test_brocken( source => 'my Int $x = 99; say dd($x);' );
    ok !$err, "no error" or diag "err=$err";
    is $out, '99', 'dd($x) with Int returns "99"';
};
subtest 'dd variable string' => sub {
    my ( $out, $err ) = test_brocken( source => 'my String $s = "world"; say dd($s);' );
    ok !$err, "no error" or diag "err=$err";
    is $out, '"world"', 'dd($s) with String returns "\"world\""';
};
subtest 'dd expression' => sub {
    my ( $out, $err ) = test_brocken( source => 'say dd(40 + 2);' );
    ok !$err, "no error" or diag "err=$err";
    is $out, '42', 'dd(40 + 2) returns "42"';
};
subtest 'dd array' => sub {
    my ( $out, $err ) = test_brocken( source => 'my Any $a = [10, 20, 30]; say dd($a);' );
    ok !$err, "no error" or diag "err=$err";
    is $out, '[10, 20, 30]', 'dd(array) returns pretty-printed array';
};
subtest 'dd tuple' => sub {
    my ( $out, $err ) = test_brocken( source => 'my Any $t = (1, 2, 3, 4); say dd($t);' );
    ok !$err, "no error" or diag "err=$err";
    is $out, '(1, 2, 3, 4)', 'dd(tuple) returns pretty-printed tuple';
};
subtest 'dd hash' => sub {
    my ( $out, $err ) = test_brocken( source => 'my Any $h = { a => 1, b => 2 }; say dd($h);' );
    ok !$err, "no error" or diag "err=$err";
    like $out, qr/^\{.*\}$/, 'dd(hash) returns { ... }';
    like $out, qr/"a": 1/,   'dd(hash) contains "a": 1';
    like $out, qr/"b": 2/,   'dd(hash) contains "b": 2';
};
subtest 'dd empty array' => sub {
    my ( $out, $err ) = test_brocken( source => 'my Any $a = []; say dd($a);' );
    ok !$err, "no error" or diag "err=$err";
    is $out, '[]', 'dd(empty array) returns "[]"';
};
subtest 'dd undef' => sub {
    my ( $out, $err ) = test_brocken( source => 'my Any $u = undef; say dd($u);' );
    ok !$err, "no error" or diag "err=$err";
    is $out, 'undef', 'dd(undef) returns "undef"';
};
subtest 'dd nested with say' => sub {
    my ( $out, $err ) = test_brocken( source => 'say "value=" . dd(42);' );
    ok !$err, "no error" or diag "err=$err";
    is $out, 'value=42', 'dd nested in string concat';
};

# --- ddx tests (STDERR output) ---
subtest 'ddx integer' => sub {
    my ( $out, $err ) = test_brocken( source => 'ddx 42;' );
    ok !$err, "no error" or diag "err=$err";
    is $out, '42', 'ddx 42 prints 42';
};
subtest 'ddx string' => sub {
    my ( $out, $err ) = test_brocken( source => 'ddx "hello";' );
    ok !$err, "no error" or diag "err=$err";
    is $out, '"hello"', 'ddx "hello" prints "hello" with quotes';
};
subtest 'ddx variable' => sub {
    my ( $out, $err ) = test_brocken( source => 'my Int $x = 7; ddx $x;' );
    ok !$err, "no error" or diag "err=$err";
    is $out, '7', 'ddx $x prints 7';
};
subtest 'ddx multiple args' => sub {
    my ( $out, $err ) = test_brocken( source => 'ddx 1, 2, 3;' );
    ok !$err, "no error" or diag "err=$err";
    is $out, '1 2 3', 'ddx 1,2,3 prints "1 2 3"';
};
subtest 'ddx expression' => sub {
    my ( $out, $err ) = test_brocken( source => 'ddx 40 + 2;' );
    ok !$err, "no error" or diag "err=$err";
    is $out, '42', 'ddx 40+2 prints 42';
};
subtest 'ddx undef' => sub {
    my ( $out, $err ) = test_brocken( source => 'my Any $u = undef; ddx $u;' );
    ok !$err, "no error" or diag "err=$err";
    is $out, 'undef', 'ddx undef prints "undef"';
};
subtest 'ddx array' => sub {
    my ( $out, $err ) = test_brocken( source => 'my Any $a = [10, 20, 30]; ddx $a;' );
    ok !$err, "no error" or diag "err=$err";
    is $out, '[10, 20, 30]', 'ddx array prints [10, 20, 30]';
};
subtest 'ddx empty array' => sub {
    my ( $out, $err ) = test_brocken( source => 'my Any $a = []; ddx $a;' );
    ok !$err, "no error" or diag "err=$err";
    is $out, '[]', 'ddx empty array prints []';
};
subtest 'ddx tuple' => sub {
    my ( $out, $err ) = test_brocken( source => 'my Any $t = (1, 2, 3, 4); ddx $t;' );
    ok !$err, "no error" or diag "err=$err";
    is $out, '(1, 2, 3, 4)', 'ddx tuple prints (1, 2, 3, 4)';
};
subtest 'ddx empty tuple' => sub {
    my ( $out, $err ) = test_brocken( source => 'my Any $t = (); ddx $t;' );
    ok !$err, "no error" or diag "err=$err";
    is $out, '()', 'ddx empty tuple prints ()';
};
subtest 'ddx hash' => sub {
    my ( $out, $err ) = test_brocken( source => 'my Any $h = { a => 1, b => 2 }; ddx $h;' );
    ok !$err, "no error" or diag "err=$err";
    like $out, qr/^\{.*\}$/, 'ddx hash prints {...}';
    like $out, qr/"a": 1/,   'ddx hash contains key "a": 1';
    like $out, qr/"b": 2/,   'ddx hash contains key "b": 2';
};
subtest 'ddx empty hash' => sub {
    my ( $out, $err ) = test_brocken( source => 'my Any $h = {}; ddx $h;' );
    ok !$err, "no error" or diag "err=$err";
    is $out, '{}', 'ddx empty hash prints {}';
};
subtest 'ddx array with strings' => sub {
    my ( $out, $err ) = test_brocken( source => 'my Any $a = ["foo", "bar"]; ddx $a;' );
    ok !$err, "no error" or diag "err=$err";
    is $out, '["foo", "bar"]', 'ddx array with strings prints ["foo", "bar"]';
};
subtest 'ddx mixed array' => sub {
    my ( $out, $err ) = test_brocken( source => 'my Any $a = [1, "two", 3]; ddx $a;' );
    ok !$err, "no error" or diag "err=$err";
    is $out, '[1, "two", 3]', 'ddx mixed array [1, "two", 3]';
};
subtest 'ddx undef literal' => sub {
    my ( $out, $err ) = test_brocken( source => 'ddx undef;' );
    ok !$err, "no error" or diag "err=$err";
    is $out, 'undef', 'ddx undef prints "undef"';
};
subtest 'ddx multiple types mixed' => sub {
    my ( $out, $err ) = test_brocken( source => 'ddx 42, "hello", undef;' );
    ok !$err, "no error" or diag "err=$err";
    is $out, '42 "hello" undef', 'ddx mixed types';
};
subtest 'ddx as statement' => sub {
    my ( $out, $err ) = test_brocken( source => 'dd(42);' );
    ok !$err, "no error" or diag "err=$err";
};
done_testing;

