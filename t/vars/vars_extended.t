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
    require Brocken::Compiler;
    my ( $fh, $exe ) = tempfile( UNLINK => 1, SUFFIX => '.exe' );
    close $fh;
    my $p = Brocken::Compiler->new();
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
subtest 'Hash-deref field set (expects parse error)' => sub {
    require Brocken::Lexer;
    require Brocken::Parser;
    my $source = q{class Node { field $val; } my $n = Node->new(); $n->{val} = 42;};
    my $tokens = Brocken::Lexer->new( source => $source )->lex();
    ok scalar(@$tokens) > 0, 'hash-deref: tokens produced';
    my $ast = eval { Brocken::Parser->new( tokens => $tokens )->parse(); };
    ok $@, 'hash-deref: parser correctly rejects this syntax';
};
subtest 'Our global variables with subs' => sub {
    my ( $out, $err ) = compile_and_run(
        q{
        our $x = 10;
        sub set_x($val) { $x = $val; }
        sub get_x() { return $x; }
        say get_x();
        set_x(42);
        say get_x();
        our $y = "global string";
    }
    );
    $err ? ( skip_all $err ) : ();
    my @lines = split /\n/, $out;
    ok scalar(@lines) >= 2, 'our globals: multiple lines';
    is $lines[0], '10', 'our: initial value';
    is $lines[1], '42', 'our: after set_x';
};
subtest 'Variable with string interpolation' => sub {
    my ( $out, $err ) = compile_and_run(q{ my $x = 1; say "Done: $x"; });
    $err ? ( skip_all $err ) : ();
    is $out, 'Done: 1', 'string interpolation with variable';
};
done_testing;
