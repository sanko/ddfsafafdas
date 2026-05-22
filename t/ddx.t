use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
use File::Temp qw(tempfile);

sub compile_and_run {
    my ( $source, %opts ) = @_;
    my $timeout     = $opts{timeout} // 15;
    my $debug       = $opts{debug}   // 0;
    my $type        = $opts{type}    // 'exe';
    my $capture_err = $opts{capture_err} // 0;
    require Brocken::Compiler;
    my ( $fh, $exe ) = tempfile( UNLINK => 1, SUFFIX => '.exe' );
    close $fh;
    my $p = Brocken::Compiler->new( debug => $debug, type => $type );
    eval { $p->compile_source( $source, $exe ); };
    if ( my $err = $@ ) {
        return ( undef, "compilation: $err" );
    }
    my $run = ( $^O eq 'MSWin32' ? '' : './' ) . $exe;
    if ($capture_err) {
        $run .= ' 2>&1';
    }
    my $output = eval {
        local $SIG{ALRM} = sub { die "TIMEOUT\n" }
            if $^O ne 'MSWin32';
        alarm($timeout) if $^O ne 'MSWin32';
        open my $fh2, '-|', $run or die "Cannot run $run: $!";
        local $/;
        my $out = <$fh2>;
        close $fh2;
        alarm(0) if $^O ne 'MSWin32';
        $out;
    };
    my $err = $@;
    alarm(0) if $^O ne 'MSWin32';
    if ($err) {
        return ( undef, "execution: $err" );
    }
    chomp $output if defined $output;
    return ( $output, undef );
}

my $has_native = 0;
{
    my ( $out, $err ) = compile_and_run('say 42;');
    $has_native = 1 if defined $out && $out eq '42';
}

if ( !$has_native ) {
    diag "Native compilation not available, skipping runtime tests";
    done_testing;
    exit;
}

# --- dd tests (return value, captured via say) ---

subtest 'dd basic integer' => sub {
    my ( $out, $err ) = compile_and_run('say dd(42);');
    ok !$err, "no error" or diag "err=$err";
    is $out, '42', 'dd(42) returns "42"';
};

subtest 'dd basic string' => sub {
    my ( $out, $err ) = compile_and_run('say dd("hello");');
    ok !$err, "no error" or diag "err=$err";
    is $out, '"hello"', 'dd("hello") returns "\"hello\""';
};

subtest 'dd variable integer' => sub {
    my ( $out, $err ) = compile_and_run('my Int $x = 99; say dd($x);');
    ok !$err, "no error" or diag "err=$err";
    is $out, '99', 'dd($x) with Int returns "99"';
};

subtest 'dd variable string' => sub {
    my ( $out, $err ) = compile_and_run('my String $s = "world"; say dd($s);');
    ok !$err, "no error" or diag "err=$err";
    is $out, '"world"', 'dd($s) with String returns "\"world\""';
};

subtest 'dd expression' => sub {
    my ( $out, $err ) = compile_and_run('say dd(40 + 2);');
    ok !$err, "no error" or diag "err=$err";
    is $out, '42', 'dd(40 + 2) returns "42"';
};

subtest 'dd array' => sub {
    my ( $out, $err ) = compile_and_run('my Any $a = [10, 20, 30]; say dd($a);');
    ok !$err, "no error" or diag "err=$err";
    is $out, '[10, 20, 30]', 'dd(array) returns pretty-printed array';
};

subtest 'dd tuple' => sub {
    my ( $out, $err ) = compile_and_run('my Any $t = (1, 2, 3, 4); say dd($t);');
    ok !$err, "no error" or diag "err=$err";
    is $out, '(1, 2, 3, 4)', 'dd(tuple) returns pretty-printed tuple';
};

subtest 'dd hash' => sub {
    my ( $out, $err ) = compile_and_run('my Any $h = { a => 1, b => 2 }; say dd($h);');
    ok !$err, "no error" or diag "err=$err";
    like $out, qr/^\{.*\}$/, 'dd(hash) returns { ... }';
    like $out, qr/"a": 1/, 'dd(hash) contains "a": 1';
    like $out, qr/"b": 2/, 'dd(hash) contains "b": 2';
};

subtest 'dd empty array' => sub {
    my ( $out, $err ) = compile_and_run('my Any $a = []; say dd($a);');
    ok !$err, "no error" or diag "err=$err";
    is $out, '[]', 'dd(empty array) returns "[]"';
};

subtest 'dd undef' => sub {
    my ( $out, $err ) = compile_and_run('my Any $u = undef; say dd($u);');
    ok !$err, "no error" or diag "err=$err";
    is $out, 'undef', 'dd(undef) returns "undef"';
};

subtest 'dd nested with say' => sub {
    my ( $out, $err ) = compile_and_run('say "value=" . dd(42);');
    ok !$err, "no error" or diag "err=$err";
    is $out, 'value=42', 'dd nested in string concat';
};

# --- ddx tests (STDERR output, captured via 2>&1) ---

subtest 'ddx integer' => sub {
    my ( $out, $err ) = compile_and_run('ddx 42;', capture_err => 1);
    ok !$err, "no error" or diag "err=$err";
    is $out, '42', 'ddx 42 prints 42';
};

subtest 'ddx string' => sub {
    my ( $out, $err ) = compile_and_run('ddx "hello";', capture_err => 1);
    ok !$err, "no error" or diag "err=$err";
    is $out, '"hello"', 'ddx "hello" prints "hello" with quotes';
};

subtest 'ddx variable' => sub {
    my ( $out, $err ) = compile_and_run('my Int $x = 7; ddx $x;', capture_err => 1);
    ok !$err, "no error" or diag "err=$err";
    is $out, '7', 'ddx $x prints 7';
};

subtest 'ddx multiple args' => sub {
    my ( $out, $err ) = compile_and_run('ddx 1, 2, 3;', capture_err => 1);
    ok !$err, "no error" or diag "err=$err";
    is $out, '1 2 3', 'ddx 1,2,3 prints "1 2 3"';
};

subtest 'ddx expression' => sub {
    my ( $out, $err ) = compile_and_run('ddx 40 + 2;', capture_err => 1);
    ok !$err, "no error" or diag "err=$err";
    is $out, '42', 'ddx 40+2 prints 42';
};

subtest 'ddx undef' => sub {
    my ( $out, $err ) = compile_and_run('my Any $u = undef; ddx $u;', capture_err => 1);
    ok !$err, "no error" or diag "err=$err";
    is $out, 'undef', 'ddx undef prints "undef"';
};

subtest 'ddx array' => sub {
    my ( $out, $err ) = compile_and_run('my Any $a = [10, 20, 30]; ddx $a;', capture_err => 1);
    ok !$err, "no error" or diag "err=$err";
    is $out, '[10, 20, 30]', 'ddx array prints [10, 20, 30]';
};

subtest 'ddx empty array' => sub {
    my ( $out, $err ) = compile_and_run('my Any $a = []; ddx $a;', capture_err => 1);
    ok !$err, "no error" or diag "err=$err";
    is $out, '[]', 'ddx empty array prints []';
};

subtest 'ddx tuple' => sub {
    my ( $out, $err ) = compile_and_run('my Any $t = (1, 2, 3, 4); ddx $t;', capture_err => 1);
    ok !$err, "no error" or diag "err=$err";
    is $out, '(1, 2, 3, 4)', 'ddx tuple prints (1, 2, 3, 4)';
};

subtest 'ddx empty tuple' => sub {
    my ( $out, $err ) = compile_and_run('my Any $t = (); ddx $t;', capture_err => 1);
    ok !$err, "no error" or diag "err=$err";
    is $out, '()', 'ddx empty tuple prints ()';
};

subtest 'ddx hash' => sub {
    my ( $out, $err ) = compile_and_run('my Any $h = { a => 1, b => 2 }; ddx $h;', capture_err => 1);
    ok !$err, "no error" or diag "err=$err";
    like $out, qr/^\{.*\}$/, 'ddx hash prints {...}';
    like $out, qr/"a": 1/, 'ddx hash contains key "a": 1';
    like $out, qr/"b": 2/, 'ddx hash contains key "b": 2';
};

subtest 'ddx empty hash' => sub {
    my ( $out, $err ) = compile_and_run('my Any $h = {}; ddx $h;', capture_err => 1);
    ok !$err, "no error" or diag "err=$err";
    is $out, '{}', 'ddx empty hash prints {}';
};

subtest 'ddx array with strings' => sub {
    my ( $out, $err ) = compile_and_run('my Any $a = ["foo", "bar"]; ddx $a;', capture_err => 1);
    ok !$err, "no error" or diag "err=$err";
    is $out, '["foo", "bar"]', 'ddx array with strings prints ["foo", "bar"]';
};

subtest 'ddx mixed array' => sub {
    my ( $out, $err ) = compile_and_run('my Any $a = [1, "two", 3]; ddx $a;', capture_err => 1);
    ok !$err, "no error" or diag "err=$err";
    is $out, '[1, "two", 3]', 'ddx mixed array [1, "two", 3]';
};

subtest 'ddx undef literal' => sub {
    my ( $out, $err ) = compile_and_run('ddx undef;', capture_err => 1);
    ok !$err, "no error" or diag "err=$err";
    is $out, 'undef', 'ddx undef prints "undef"';
};

subtest 'ddx multiple types mixed' => sub {
    my ( $out, $err ) = compile_and_run('ddx 42, "hello", undef;', capture_err => 1);
    ok !$err, "no error" or diag "err=$err";
    is $out, '42 "hello" undef', 'ddx mixed types';
};

subtest 'ddx as statement' => sub {
    my ( $out, $err ) = compile_and_run('dd(42);');
    ok !$err, "no error" or diag "err=$err";
};

done_testing;
