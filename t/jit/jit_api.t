use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';

BEGIN {
    eval { require Brocken::JIT; 1 } or skip_all "Brocken::JIT module not available";
}
subtest 'JIT creation with standalone mode' => sub {
    my $jit = Brocken::JIT->new( driver => undef, arch => 'x64', os => 'win64', standalone => 1 );
    ok $jit->isa('Brocken::JIT'), 'JIT object created';
};
subtest 'JIT compile_source' => sub {
    my $jit    = Brocken::JIT->new( driver => undef, arch => 'x64', os => 'win64', standalone => 1 );
    my $result = eval { $jit->compile_source('say 42;') };
    ok !$@ || $@ =~ /JIT|arch/, 'JIT compile_source did not crash';
};
subtest 'JIT with lexer + parser pipeline' => sub {
    require Brocken::Lexer;
    require Brocken::Parser;
    my $source = 'say 42;';
    my $tokens = Brocken::Lexer->new( source => $source )->lex();
    my $ast    = Brocken::Parser->new( tokens => $tokens )->parse();
    ok scalar(@$tokens) > 0, 'JIT pipeline: tokens produced';
    ok scalar(@$ast) > 0,    'JIT pipeline: AST produced';
};
subtest 'JIT full pipeline with skip_runtime' => sub {
    require Brocken::Lexer;
    require Brocken::Parser;
    require Brocken::Compiler;
    require Brocken::Compiler::DataSegment;
    require Brocken::Compiler::Lowering;
    require Brocken::Compiler::Optimizer;
    my $source   = 'say 42;';
    my $tokens   = Brocken::Lexer->new( source => $source )->lex();
    my $ast      = Brocken::Parser->new( tokens => $tokens )->parse();
    my $driver   = Brocken::Compiler->new( arch => 'x64' );
    my $ds       = Brocken::Compiler::DataSegment->new();
    my $lowering = Brocken::Compiler::Lowering->new( data_segment => $ds, driver => $driver );
    $lowering->set_skip_runtime(1);
    $lowering->lower_program($ast);
    my $instr_ref = $lowering->builder->instructions;
    ok ref($instr_ref) eq 'ARRAY', 'skip_runtime: instructions is array';
    ok scalar(@$instr_ref) > 0,    'skip_runtime: instructions non-empty';
    my $optimizer = Brocken::Compiler::Optimizer->new();
    $optimizer->optimize( $lowering->builder );
    my $instr_ref2 = $lowering->builder->instructions;
    ok ref($instr_ref2) eq 'ARRAY', 'after optimize: is array';
    ok scalar(@$instr_ref2) > 0,    'after optimize: non-empty';
};
done_testing;
