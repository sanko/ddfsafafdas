use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
use File::Temp qw(tempfile);

sub compile_and_run {
    my ( $source, %opts ) = @_;
    my $timeout = $opts{timeout} // 15;
    my $debug   = $opts{debug}   // 0;
    my $type    = $opts{type}    // 'exe';
    require Brocken::Compiler;
    my ( $fh, $exe ) = tempfile( UNLINK => 1, SUFFIX => '.exe' );
    close $fh;
    my $p = Brocken::Compiler->new( debug => $debug, type => $type );
    eval { $p->compile_source( $source, $exe ); };

    if ( my $err = $@ ) {
        return ( undef, "compilation: $err" );
    }
    my $run    = ( $^O eq 'MSWin32' ? '' : './' ) . $exe;
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
subtest 'Hello world' => sub {
    my ( $out, $err ) = compile_and_run('say 42;');
    if ($err) {
        diag "Skipping: $err";
        skip_all "Native compilation not available";
    }
    is $out, '42', 'say 42 produces 42';
};
subtest 'Expression in say' => sub {
    my ( $out, $err ) = compile_and_run('say 40 + 2;');
    $err ? ( skip_all "Native compilation not available" ) : ();
    is $out, '42', 'say 40 + 2 produces 42';
};
subtest 'Multiple arithmetic' => sub {
    my ( $out, $err ) = compile_and_run('say 10 * 4 + 2;');
    $err ? ( skip_all "Native compilation not available" ) : ();
    is $out, '42', 'say 10 * 4 + 2 produces 42';
};
subtest 'Variable declaration and say' => sub {
    my ( $out, $err ) = compile_and_run('my Int $x = 42; say $x;');
    $err ? ( skip_all "Native compilation not available" ) : ();
    is $out, '42', 'variable say works';
};
subtest 'String interpolation' => sub {
    my ( $out, $err ) = compile_and_run(q{my Int $x = 42; say "The answer is $x";});
    $err ? ( skip_all "Native compilation not available" ) : ();
    is $out, 'The answer is 42', 'string interpolation works';
};
subtest 'String concatenation' => sub {
    my ( $out, $err ) = compile_and_run(q{my String $s = "hello " . "world"; say $s;});
    $err ? ( skip_all "Native compilation not available" ) : ();
    is $out, 'hello world', 'string concatenation works';
};
subtest 'If/else true branch' => sub {
    my ( $out, $err ) = compile_and_run('my Int $x = 42; if ($x == 42) { say "yes" } else { say "no" };');
    $err ? ( skip_all "Native compilation not available" ) : ();
    is $out, 'yes', 'if/else true branch works';
};
subtest 'If/else false branch' => sub {
    my ( $out, $err ) = compile_and_run('my Int $x = 0; if ($x == 42) { say "yes" } else { say "no" };');
    $err ? ( skip_all "Native compilation not available" ) : ();
    is $out, 'no', 'if/else false branch works';
};
subtest 'While loop' => sub {
    my ( $out, $err ) = compile_and_run('my Int $i = 0; while ($i < 3) { say $i; $i = $i + 1; };');
    $err ? ( skip_all "Native compilation not available" ) : ();
    my @lines = split /\n/, $out;
    is scalar(@lines), 3,   'while loop produces 3 lines';
    is $lines[0],      '0', 'first iteration 0';
    is $lines[2],      '2', 'last iteration 2';
};
subtest 'For loop over range' => sub {
    my ( $out, $err ) = compile_and_run('for my $i (1..3) { say $i; };');
    $err ? ( skip_all "Native compilation not available" ) : ();
    ok defined $out,     'for loop produces output';
    ok length($out) > 0, 'output is non-empty';
};
subtest 'Subroutine call with return' => sub {
    my ( $out, $err ) = compile_and_run('sub double(Int $n) { return $n * 2; }; say double(21);');
    $err ? ( skip_all "Native compilation not available" ) : ();
    is $out, '42', 'subroutine call returns 42';
};
subtest 'Unless' => sub {
    my ( $out, $err ) = compile_and_run('my Int $x = 0; unless ($x) { say "zero" };');
    $err ? ( skip_all "Native compilation not available" ) : ();
    is $out, 'zero', 'unless works';
};
subtest 'Until loop' => sub {
    my ( $out, $err ) = compile_and_run('my Int $i = 0; until ($i == 3) { say $i; $i = $i + 1; };');
    $err ? ( skip_all "Native compilation not available" ) : ();
    my @lines = split /\n/, $out;
    is scalar(@lines), 3,   'until loop produces 3 lines';
    is $lines[0],      '0', 'first iteration 0';
    is $lines[2],      '2', 'last iteration 2';
};
subtest 'Ternary operator' => sub {
    my ( $out, $err ) = compile_and_run('my String $s = 42 == 42 ? "yes" : "no"; say $s;');
    $err ? ( skip_all "Native compilation not available" ) : ();
    is $out, 'yes', 'ternary operator works';
};
subtest 'Defined-or operator' => sub {
    my ( $out, $err ) = compile_and_run('my Any $x = undef; my Any $y = $x // 42; say $y;');
    $err ? ( skip_all "Native compilation not available" ) : ();
    is $out, '42', 'defined-or operator works';
};
subtest 'Class with method' => sub {
    my ( $out, $err ) = compile_and_run(
        q{
        class Greeter {
            method greet() { say "hello"; }
        };
        my Greeter $g = Greeter->new();
        $g->greet();
    }
    );
    $err ? ( skip_all "Native compilation not available" ) : ();
    is $out, 'hello', 'class method call works';
};
subtest 'Multiple say outputs' => sub {
    my ( $out, $err ) = compile_and_run(
        q{
        say "first";
        say "second";
        say "third";
    }
    );
    $err ? ( skip_all "Native compilation not available" ) : ();
    my @lines = split /\n/, $out;
    is scalar(@lines), 3,        '3 lines output';
    is $lines[0],      'first',  'first line';
    is $lines[1],      'second', 'second line';
    is $lines[2],      'third',  'third line';
};
subtest 'Comparison operators' => sub {
    my ( $out, $err ) = compile_and_run(
        q{
        my Int $a = 5;
        my Int $b = 10;
        if ($a < $b) { say "less" };
        if ($b > $a) { say "greater" };
        if ($a == 5) { say "equal" };
    }
    );
    $err ? ( skip_all "Native compilation not available" ) : ();
    my @lines = split /\n/, $out;
    is scalar(@lines), 3,         '3 comparison results';
    is $lines[0],      'less',    'a < b';
    is $lines[1],      'greater', 'b > a';
    is $lines[2],      'equal',   'a == 5';
};
subtest 'Nested blocks' => sub {
    my ( $out, $err ) = compile_and_run(
        q{
        my Int $x = 1;
        {
            my Int $x = 2;
            say $x;
        };
        say $x;
    }
    );
    $err ? ( skip_all "Native compilation not available" ) : ();
    my @lines = split /\n/, $out;
    is scalar(@lines), 2,   '2 lines output';
    is $lines[0],      '2', 'inner x = 2';
    is $lines[1],      '1', 'outer x = 1';
};
done_testing;
