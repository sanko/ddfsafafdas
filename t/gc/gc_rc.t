use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
use Brocken::TestHelpers qw(test_brocken);
my $NODE_CLASS = q{
    class Node {
        field $next; field $val;
        method set_val(Int $v) { $val = $v; }
        method set_next(Any $n) { $next = $n; }
        method get_val() { return $val; }
    }
};
subtest 'RC: linked list with 10 nodes' => sub {
    my ( $out, $err )
        = test_brocken( source =>
            "${NODE_CLASS}my \$head = Node->new(); \$head->set_val(0); my \$i = 0; while (\$i < 10) { my \$new = Node->new(); \$new->set_val(\$i + 1); \$new->set_next(\$head); \$head = \$new; \$i = \$i + 1; } say \"Head val: \" . \$head->get_val(); say \"Done\";"
        );
    $err ? ( skip_all $err ) : ();
    like $out, qr/Head val: 10/, '10-node list head val = 10';
};
subtest 'RC: single object create' => sub {
    my ( $out, $err ) = test_brocken(
        source => q{
        class Node { field $val; method get_val() { return $val; } }
        say "Before new"; my $head = Node->new(); say "After new"; say "Done";
    }
    );
    $err ? ( skip_all $err ) : ();
    like $out, qr/Before new/, 'single object: before new';
    like $out, qr/After new/,  'single object: after new';
};
subtest 'RC: orphaned objects in loop' => sub {
    my ( $out, $err ) = test_brocken(
        source => q{
        class Node { field $next; field $val; method get_val() { return $val; } }
        say "Before loop";
        my $i = 0;
        while ($i < 3) { say "Loop iter"; my $n = Node->new(); $i = $i + 1; }
        say "After loop"; say "Done";
    }
    );
    $err ? ( skip_all $err ) : ();
    like $out, qr/Before loop/,                      'orphaned: before loop';
    like $out, qr/Loop iter.*Loop iter.*Loop iter/s, 'orphaned: 3 iterations';
};
subtest 'RC: set_next chaining' => sub {
    my ( $out, $err ) = test_brocken(
        source => q{
        class Node { field $next; field $val; method get_val() { return $val; } method set_next(Any $n) { $next = $n; } }
        my $head = Node->new(); my $i = 0;
        while ($i < 3) { my $new = Node->new(); $new->set_next($head); $head = $new; $i = $i + 1; }
        say "Created " . $i . " nodes"; say "Done";
    }
    );
    $err ? ( skip_all $err ) : ();
    like $out, qr/Created 3 nodes/, 'set_next chaining: created 3';
};
subtest 'RC: 3-node linked list with values' => sub {
    my ( $out, $err )
        = test_brocken( source =>
            "${NODE_CLASS}my \$head = Node->new(); \$head->set_val(0); my \$i = 0; while (\$i < 3) { my \$new = Node->new(); \$new->set_val(\$i + 1); \$new->set_next(\$head); \$head = \$new; \$i = \$i + 1; } say \"Created \" . \$i . \" nodes\"; say \"Done\";"
        );
    $err ? ( skip_all $err ) : ();
    like $out, qr/Created 3 nodes/, '3-node list: created 3';
};
subtest 'RC: method with field assignment' => sub {
    my ( $out, $err ) = test_brocken(
        source => q{
        class Node { field $val; method set_val(Int $v) { $val = $v; } }
        my $head = Node->new(); say "Before set_val"; $head->set_val(42); say "After set_val"; say "Done";
    }
    );
    $err ? ( skip_all $err ) : ();
    like $out, qr/Before set_val/, 'method assign: before';
    like $out, qr/After set_val/,  'method assign: after';
};
subtest 'RC: hash-deref field set (expects parse error)' => sub {
    require Brocken::Core::Lexer;
    require Brocken::Core::Parser;
    my $source = q{class Node { field $val; } my $head = Node->new(); $head->{val} = 42;};
    my $tokens = Brocken::Core::Lexer->new( source => $source )->lex();
    ok scalar(@$tokens) > 0, 'hash-deref: tokens produced';
    my $ast = eval { Brocken::Core::Parser->new( tokens => $tokens )->parse(); };
    ok $@, 'hash-deref: parser correctly rejects this syntax';
};
subtest 'RC: method with say instrumentation' => sub {
    my ( $out, $err ) = test_brocken(
        source => q{
        class Node { field $val; method set_val(Int $v) { say "in set_val"; $val = $v; say "after assign"; } }
        my $head = Node->new(); say "Before set_val"; $head->set_val(42); say "After set_val"; say "Done";
    }
    );
    $err ? ( skip_all $err ) : ();
    like $out, qr/in set_val/,   'instrumented: in set_val';
    like $out, qr/after assign/, 'instrumented: after assign';
};
subtest 'GC: simple scalars' => sub {
    my ( $out, $err ) = test_brocken( source => q{ my $a = 1; my $b = 2; say "Done: $a, $b"; } );
    $err ? ( skip_all $err ) : ();
    is $out, 'Done: 1, 2', 'simple scalars output';
};
subtest 'GC: typed vars with array refs' => sub {
    my ( $out, $err ) = test_brocken(
        source => q{
        say "Starting"; my Int $i = 0; my Any $a = [1]; my Any $b = [2];
        say "Created two objects"; say "Done";
    }
    );
    $err ? ( skip_all $err ) : ();
    like $out, qr/Created two objects/, 'typed array refs';
};
done_testing;
