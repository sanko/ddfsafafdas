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

subtest 'dd basic integer' => sub {
    my ( $out, $err ) = compile_and_run('say dd(42);');
    ok !$err, "no error" or diag "err=$err";
    is $out, '42', 'dd(42) returns "42"';
};

subtest 'dd basic string' => sub {
    my ( $out, $err ) = compile_and_run('say dd("hello");');
    ok !$err, "no error" or diag "err=$err";
    is $out, 'hello', 'dd("hello") returns "hello"';
};

subtest 'dd variable integer' => sub {
    my ( $out, $err ) = compile_and_run('my Int $x = 99; say dd($x);');
    ok !$err, "no error" or diag "err=$err";
    is $out, '99', 'dd($x) with Int returns "99"';
};

subtest 'dd variable string' => sub {
    my ( $out, $err ) = compile_and_run('my String $s = "world"; say dd($s);');
    ok !$err, "no error" or diag "err=$err";
    is $out, 'world', 'dd($s) with String returns "world"';
};

subtest 'dd expression' => sub {
    my ( $out, $err ) = compile_and_run('say dd(40 + 2);');
    ok !$err, "no error" or diag "err=$err";
    is $out, '42', 'dd(40 + 2) returns "42"';
};

subtest 'ddx integer' => sub {
    my ( $out, $err ) = compile_and_run('ddx 42;');
    ok !$err, "no error" or diag "err=$err";
};

subtest 'ddx string' => sub {
    my ( $out, $err ) = compile_and_run('ddx "hello";');
    ok !$err, "no error" or diag "err=$err";
};

subtest 'ddx variable' => sub {
    my ( $out, $err ) = compile_and_run('my Int $x = 7; ddx $x;');
    ok !$err, "no error" or diag "err=$err";
};

subtest 'ddx multiple args' => sub {
    my ( $out, $err ) = compile_and_run('ddx 1, 2, 3;');
    ok !$err, "no error" or diag "err=$err";
};

subtest 'ddx expression' => sub {
    my ( $out, $err ) = compile_and_run('ddx 40 + 2;');
    ok !$err, "no error" or diag "err=$err";
};

subtest 'dd as statement' => sub {
    my ( $out, $err ) = compile_and_run('dd(42);');
    ok !$err, "no error" or diag "err=$err";
};

done_testing;
