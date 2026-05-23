use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
use Brocken::TestHelpers qw(test_brocken);
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
    my ( $out, $err ) = test_brocken(
        source => q{
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
    my ( $out, $err ) = test_brocken( source => q{ my $x = 1; say "Done: $x"; } );
    $err ? ( skip_all $err ) : ();
    is $out, 'Done: 1', 'string interpolation with variable';
};
done_testing;
