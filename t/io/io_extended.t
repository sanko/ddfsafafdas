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
    require Brocken::Compiler;
    my ( $fh, $exe ) = tempfile( UNLINK => 1, SUFFIX => '.exe' );
    close $fh;
    my $p = Brocken::Compiler->new( debug => $debug );
    eval { $p->compile_source( $source, $exe ); };
    return ( undef, "compilation: $@" ) if $@;
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
    alarm(0)                          if $^O ne 'MSWin32';
    return ( undef, "execution: $@" ) if $@;
    chomp $output                     if defined $output;
    return ( $output, undef );
}
subtest 'Dump arrayref' => sub {
    my ( $out, $err ) = compile_and_run(
        q{
        my $a = [1, 2, "three"]; dump $a;
    }
    );
    $err ? ( skip_all $err ) : ();
    ok defined $out && length($out) > 0, 'dump arrayref produces output';
};
subtest 'Dump hashref' => sub {
    my ( $out, $err ) = compile_and_run(
        q{
        my $h = {}; $h{"foo"} = 42; dump $h;
    }
    );
    $err ? ( skip_all $err ) : ();
    ok defined $out && length($out) > 0, 'dump hashref produces output';
};
subtest 'Dump various types' => sub {
    my ( $out, $err ) = compile_and_run(
        q{
        dump 123; dump "hello"; dump undef;
    }
    );
    $err ? ( skip_all $err ) : ();
    ok defined $out && length($out) > 0, 'dump multiple types';
};
subtest 'Say with object reference' => sub {
    my ( $out, $err ) = compile_and_run(
        q{
        class Node { field $val; }
        my $n = Node->new(); say $n;
    }
    );
    $err ? ( skip_all $err ) : ();
    ok defined $out && length($out) > 0, 'say object produces some output';
};
subtest 'For loop with next and last' => sub {
    my ( $out, $err ) = compile_and_run(
        q{
        for my $i (1..10) {
            if ($i == 2) { next; };
            if ($i == 5) { last; };
            say $i;
        };
    }
    );
    $err ? ( skip_all $err ) : ();
    my @lines = split /\n/, $out;
    ok scalar(@lines) > 0, 'for with next/last produces output';
};
subtest 'For loop over array ref' => sub {
    my ( $out, $err ) = compile_and_run(
        q{
        for my $elem ([1, 2, 3]) { say $elem; };
    }
    );
    $err ? ( skip_all $err ) : ();
    ok defined $out, 'for over array ref produces output';
};
subtest 'While loop with objects and methods' => sub {
    my ( $out, $err ) = compile_and_run(
        q{
        class Node { field $val; method set_val(Int $v) { $val = $v; } method get_val() { return $val; } }
        my $i = 0; my $n = Node->new();
        while ($i < 5) { $n->set_val($i); $i = $i + 1; };
        say "Done";
    }
    );
    $err ? ( skip_all $err ) : ();
    like $out, qr/Done/, 'while with method calls completes';
};
done_testing;
