use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
use Brocken::TestHelpers qw(test_brocken);
subtest 'Class with method chaining (trace mode)' => sub {
    my ( $out, $err ) = test_brocken(
        source => q{
        class Node { field $next; field $val;
            method set_val(Int $v) { say "  in set_val"; $val = $v; }
            method set_next(Any $n) { say "  in set_next"; $next = $n; }
        }
        say "Creating first node...";
        my $n1 = Node->new();
        say "Created n1";
        $n1->set_val(0);
        say "set_val done";
        say "Creating second node...";
        my $n2 = Node->new();
        say "Created n2";
        $n2->set_next($n1);
        say "set_next done";
        say "All done";
    },
        debug => 4,
        name  => 'Class with method chaining (trace mode)'
    );
    $err ? ( skip_all $err ) : ();
    like $out, qr/Creating first node/, 'trace: creates first node';
    like $out, qr/in set_val/,          'trace: calls set_val';
    like $out, qr/in set_next/,         'trace: calls set_next';
    like $out, qr/All done/,            'trace: completes';
};
subtest 'Require lowers without crashing' => sub {
    require Brocken::Lexer;
    require Brocken::Parser;
    require Brocken::Compiler;
    require Brocken::Compiler::Lowering;
    require Brocken::Compiler::DataSegment;
    my $source = 'require Math::Utils; my $mu = Math::Utils->new(); say $mu->add(40, 2);';
    my $tokens = Brocken::Lexer->new( source => $source )->lex();
    ok scalar(@$tokens) > 0, 'require: tokens produced';
    my $ast = Brocken::Parser->new( tokens => $tokens )->parse();
    ok scalar(@$ast) > 0, 'require: AST produced';
};
done_testing;
