use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
use Brocken::Compiler::Lowering;
use Brocken::Compiler::DataSegment;
use Brocken::Compiler::Pipeline;
my $setup = sub {
    my ($source) = @_;
    require Brocken::Core::Lexer;
    require Brocken::Core::Parser;
    my $tokens = Brocken::Core::Lexer->new( source => $source )->lex();
    my $ast    = Brocken::Core::Parser->new( tokens => $tokens )->parse();
    my $ds     = Brocken::Compiler::DataSegment->new;
    my $driver = Brocken::Compiler::Pipeline->new;
    my $l      = Brocken::Compiler::Lowering->new( data_segment => $ds, driver => $driver );
    $l->lower_program($ast);
    return $l;
};
subtest 'Return with expression' => sub {
    my $l     = $setup->('sub foo() { return 42; }');
    my @insts = $l->builder->instructions;
    ok scalar(@insts) > 0, 'return with expr produces instructions';
    my @rets = grep { $_->{op} eq 'return' || ( $_->{op} eq 'leave_func' && defined $_->{args}[0] ) } @insts;
    ok scalar(@rets) >= 1, 'return includes value';
};
subtest 'Return without expression' => sub {
    my $l     = $setup->('sub bar() { return; }');
    my @insts = $l->builder->instructions;
    ok scalar(@insts) > 0, 'return without expr produces instructions';
};
subtest 'Defer statement' => sub {
    my $l     = $setup->('defer { say "cleanup"; }');
    my @insts = $l->builder->instructions;
    ok scalar(@insts) > 0, 'defer produces instructions';
};
subtest 'Next/Last/Redo in loop' => sub {
    my $l     = $setup->('for my $x (1..5) { if ($x == 3) { last; } next; redo; }');
    my @insts = $l->builder->instructions;
    ok scalar(@insts) > 0, 'loop control produces instructions';
};
subtest 'Try/Catch' => sub {
    my $l     = $setup->('try { say "try" } catch($e) { say "caught" }');
    my @insts = $l->builder->instructions;
    ok scalar(@insts) > 0, 'try/catch produces instructions';
    my @try_markers = grep { $_->{op} eq 'mark_try_start' } @insts;
    ok scalar(@try_markers) >= 1, 'try/catch emits mark_try_start';
};
subtest 'Try/Catch/Finally' => sub {
    my $l     = $setup->('try { say "try" } catch($e) { say "caught" } finally { say "done" }');
    my @insts = $l->builder->instructions;
    ok scalar(@insts) > 0, 'try/catch/finally produces instructions';
    my @ends = grep { $_->{op} eq 'mark_try_end' } @insts;
    ok scalar(@ends) >= 1, 'try/catch/finally emits mark_try_end';
};
subtest 'Die statement' => sub {
    my $l     = $setup->('die "error message";');
    my @insts = $l->builder->instructions;
    ok scalar(@insts) > 0, 'die produces instructions';
};
subtest 'Exit statement' => sub {
    my $l     = $setup->('exit(0);');
    my @insts = $l->builder->instructions;
    ok scalar(@insts) > 0, 'exit produces instructions';
};
subtest 'State variable' => sub {
    my $l     = $setup->('sub baz() { state Int $count = 0; $count = $count + 1; }');
    my @insts = $l->builder->instructions;
    ok scalar(@insts) > 0, 'state variable produces instructions';
};
subtest 'Our declaration' => sub {
    my $l     = $setup->('our Int $x = 10;');
    my @insts = $l->builder->instructions;
    ok scalar(@insts) > 0, 'our declaration produces instructions';
};
subtest 'Array literal' => sub {
    my $l     = $setup->('my @arr = [1, 2, 3];');
    my @insts = $l->builder->instructions;
    ok scalar(@insts) > 0, 'array literal produces instructions';
};
subtest 'Hash literal in say' => sub {
    my $l     = $setup->('say "hash test";');
    my @insts = $l->builder->instructions;
    ok scalar(@insts) > 0, 'say produces instructions';
};
subtest 'Unless' => sub {
    my $l     = $setup->('unless (0) { say "no"; }');
    my @insts = $l->builder->instructions;
    ok scalar(@insts) > 0, 'unless produces instructions';
    my @conds = grep { $_->{op} eq 'cond_br' } @insts;
    ok scalar(@conds) >= 1, 'unless produces conditional branch';
};
subtest 'Until loop' => sub {
    my $l     = $setup->('my Int $x = 0; until ($x == 5) { $x = $x + 1; }');
    my @insts = $l->builder->instructions;
    ok scalar(@insts) > 0, 'until produces instructions';
    my @jumps = grep { $_->{op} eq 'jmp' } @insts;
    ok scalar(@jumps) >= 1, 'until produces jump (back-edge)';
};
subtest 'Yada operator' => sub {
    my $l     = $setup->('...;');
    my @insts = $l->builder->instructions;
    ok scalar(@insts) > 0, 'yada produces instructions';
};
subtest 'Map expression' => sub {
    my $l     = $setup->('my @result = map { $_ * 2 } [1, 2, 3];');
    my @insts = $l->builder->instructions;
    ok scalar(@insts) > 0, 'map produces instructions';
    my @map_ops = grep { $_->{op} eq 'map_op' } @insts;
    ok scalar(@map_ops) >= 1, 'map produces map_op';
};
subtest 'Fiber block' => sub {
    my $l     = $setup->('my $f = fiber { say "hello"; };');
    my @insts = $l->builder->instructions;
    ok scalar(@insts) > 0, 'fiber block produces instructions';
};
subtest 'Method call (constructor)' => sub {
    my $l     = $setup->('class Foo { field Int $x; method new() { return $self; } } Foo->new();');
    my @insts = $l->builder->instructions;
    ok scalar(@insts) > 0, 'method call produces instructions';
};
subtest 'String say with variable' => sub {
    my $l     = $setup->('my Int $x = 42; say $x;');
    my @insts = $l->builder->instructions;
    ok scalar(@insts) > 0, 'say with variable produces instructions';
};
subtest 'Multiple statements in block' => sub {
    my $l     = $setup->('{ my Int $a = 1; my Int $b = 2; my Int $c = $a + $b; }');
    my @insts = $l->builder->instructions;
    ok scalar(@insts) > 0, 'block with multiple stmts produces instructions';
};
subtest 'Nested if/else' => sub {
    my $l     = $setup->('if (1) { if (0) { say "nested"; } else { say "else"; } }');
    my @insts = $l->builder->instructions;
    ok scalar(@insts) > 0, 'nested if produces instructions';
};
subtest 'Binary operators' => sub {
    my $l     = $setup->('my Int $r = 10 + 20 * 3 - 5 / 2;');
    my @insts = $l->builder->instructions;
    ok scalar(@insts) > 0, 'multiple binops produce instructions';
    my @add = grep { $_->{op} eq 'add' } @insts;
    ok scalar(@add) >= 1, 'produces add instruction';
};
done_testing;


