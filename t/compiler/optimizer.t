use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
use Brocken::Compiler::Optimizer;
use Brocken::Core::IR::Builder;
use Brocken::AST;

sub build_ir {
    my $b = Brocken::Core::IR::Builder->new;
    $b->emit( 'enter_func', 'void', [] );
    return $b;
}
subtest 'Tail call optimization: call_func -> tail_call_func' => sub {
    my $b = build_ir;
    my $r = $b->emit( 'constant', 'Int', [42] );
    $b->emit( 'call_func', 'Int', ['foo'], $r );
    $b->emit( 'leave_func', 'void', [$r] );
    my $opt = Brocken::Compiler::Optimizer->new;
    $opt->optimize($b);
    my $insts = $b->instructions;
    ok scalar(@$insts) >= 1, 'instructions remain';
    my $tc = ( grep { $_->{op} eq 'tail_call_func' } @$insts )[0];
    ok $tc, 'tail_call_func exists in output';
};
subtest 'Tail call optimization: call_reg -> tail_call_reg' => sub {
    my $b = build_ir;
    my $r = $b->emit( 'constant', 'Int', [0] );
    $b->emit( 'call_reg', 'Int', ['%5'], $r );
    $b->emit( 'leave_func', 'void', [$r] );
    my $opt = Brocken::Compiler::Optimizer->new;
    $opt->optimize($b);
    my $insts = $b->instructions;
    my $tc    = ( grep { $_->{op} eq 'tail_call_reg' } @$insts )[0];
    ok $tc, 'tail_call_reg exists in output';
};
subtest 'Tail call not optimized when dest doesnt match leave_func arg' => sub {
    my $b = build_ir;
    my $r = $b->emit( 'constant', 'Int', [1] );
    $b->emit( 'call_func', 'Int', ['foo'], $r );
    $b->emit( 'leave_func', 'void', ['%999'] );
    my $opt = Brocken::Compiler::Optimizer->new;
    $opt->optimize($b);
    my $insts = $b->instructions;
    my $cf    = ( grep { $_->{op} eq 'call_func' } @$insts )[0];
    ok $cf, 'call_func still exists when arg mismatch';
};
subtest 'Leaf function identification' => sub {
    my $b = build_ir;
    $b->emit( 'constant',   'Int',  [10] );
    $b->emit( 'leave_func', 'void', ['%2'] );
    my $opt = Brocken::Compiler::Optimizer->new;
    $opt->optimize($b);
    my $insts = $b->instructions;
    my $elf   = ( grep { $_->{op} eq 'enter_leaf_func' } @$insts )[0];
    ok $elf, 'enter_leaf_func exists for leaf function';
};
subtest 'Non-leaf function has enter_func' => sub {
    my $b = build_ir;
    $b->emit( 'call_func', 'Int', ['foo'], '%3' );
    $b->emit( 'leave_func', 'void', ['%3'] );
    my $opt = Brocken::Compiler::Optimizer->new;
    $opt->optimize($b);
    my $insts = $b->instructions;
    my $ef    = ( grep { $_->{op} eq 'enter_func' } @$insts )[0];
    ok $ef, 'enter_func preserved for non-leaf function';
};
subtest 'Dead instruction elimination' => sub {
    my $b  = Brocken::Core::IR::Builder->new;
    my $v1 = $b->emit( 'constant', 'Int', [10] );
    $b->emit( 'constant',   'Int',  [20] );
    $b->emit( 'leave_func', 'void', [$v1] );
    my $opt = Brocken::Compiler::Optimizer->new;
    $opt->optimize($b);
    my $insts = $b->instructions;
    my $used  = ( grep { $_->{op} eq 'constant' } @$insts )[0];
    ok $used, 'used constant preserved';
    my @unused = grep { $_->{op} eq 'constant' } @$insts;
    is scalar(@unused), 1, 'only one constant left (unused eliminated)';
};
subtest 'Map fusion' => sub {
    my $b  = Brocken::Core::IR::Builder->new;
    my $v1 = $b->new_reg;
    $b->emit_label('L_entry');
    $b->push_instruction(
        {   op   => 'map_op',
            dest => $v1,
            args => [
                '%src',
                Brocken::AST::Expr::BinOp->new(
                    op    => '*',
                    left  => Brocken::AST::Expr::Var->new( name => '$_' ),
                    right => Brocken::AST::Expr::Const->new( value => 2, type => 'Int' ),
                )
            ]
        }
    );
    my $v2 = $b->new_reg;
    $b->push_instruction(
        {   op   => 'map_op',
            dest => $v2,
            args => [
                $v1,
                Brocken::AST::Expr::BinOp->new(
                    op    => '+',
                    left  => Brocken::AST::Expr::Var->new( name => '$_' ),
                    right => Brocken::AST::Expr::Const->new( value => 1, type => 'Int' ),
                )
            ]
        }
    );
    $b->push_instruction( { op => 'shadow_push', args => [$v2] } );
    my $opt = Brocken::Compiler::Optimizer->new;
    $opt->optimize($b);
    my $insts   = $b->instructions;
    my @map_ops = grep { $_->{op} eq 'map_op' } @$insts;
    is scalar(@map_ops), 1, 'two map_ops merged into one';
};
subtest 'AST substitution' => sub {
    my $opt    = Brocken::Compiler::Optimizer->new;
    my $var    = Brocken::AST::Expr::Var->new( name => '$_' );
    my $repl   = Brocken::AST::Expr::Const->new( value => 99,  type => 'Int' );
    my $binop  = Brocken::AST::Expr::BinOp->new( op    => '+', left => $var, right => Brocken::AST::Expr::Const->new( value => 1, type => 'Int' ), );
    my $result = $opt->substitute_ast( $binop, '$_', $repl );
    ok $result->isa('Brocken::AST::Expr::BinOp'), 'result is BinOp';
    is $result->left->value,  99, '$_ replaced with 99';
    is $result->right->value, 1,  'right unchanged';
};
done_testing;


