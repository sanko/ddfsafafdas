use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
use Brocken::Core::Lexer;
use Brocken::Core::Parser;

sub parse {
    my ($source) = @_;
    my $tokens = Brocken::Core::Lexer->new( source => $source )->lex();
    return Brocken::Core::Parser->new( tokens => $tokens )->parse();
}
subtest 'Arithmetic Precedence' => sub {
    my $ast = parse('1 + 2 * 3;');
    is( scalar @$ast, 1, 'One statement' );
    my $node = $ast->[0];
    isa_ok( $node, 'Brocken::AST::Expr::BinOp' );
    is( $node->op,          '+', 'Root is +' );
    is( $node->left->value, 1,   'Left is 1' );
    isa_ok( $node->right, 'Brocken::AST::Expr::BinOp' );
    is( $node->right->op,           '*', 'Right is *' );
    is( $node->right->left->value,  2,   '2' );
    is( $node->right->right->value, 3,   '3' );
};
subtest 'Parentheses' => sub {
    my $ast  = parse('(1 + 2) * 3;');
    my $node = $ast->[0];
    is( $node->op,       '*', 'Root is * due to parens' );
    is( $node->left->op, '+', 'Left is +' );
};
subtest 'Variable Declaration and Assignment' => sub {
    my $ast = parse('my Int $x = 10; $x = 20;');
    is( scalar @$ast, 2, 'Two statements' );
    isa_ok( $ast->[0], 'Brocken::AST::Stmt::VarDecl' );
    is( $ast->[0]->name, '$x',  'my $x' );
    is( $ast->[0]->type, 'Int', 'type Int' );
    isa_ok( $ast->[1], 'Brocken::AST::Stmt::Assignment' );
    is( $ast->[1]->name,         '$x', 'assignment to $x' );
    is( $ast->[1]->value->value, 20,   'value 20' );
};
subtest 'Control Flow: If/Else' => sub {
    my $ast  = parse('if ($x) { say 1; } else { say 0; }');
    my $node = $ast->[0];
    isa_ok( $node, 'Brocken::AST::Stmt::If' );
    ok( $node->condition, 'has condition' );
    isa_ok( $node->then_block, 'Brocken::AST::Stmt::Block' );
    isa_ok( $node->else_block, 'Brocken::AST::Stmt::Block' );
};
subtest 'Control Flow: While' => sub {
    my $ast  = parse('while (1) { say "loop"; }');
    my $node = $ast->[0];
    isa_ok( $node, 'Brocken::AST::Stmt::While' );
    is( $node->condition->value, 1, 'while(1)' );
    isa_ok( $node->body, 'Brocken::AST::Stmt::Block' );
};
subtest 'OOP: Class and Method' => sub {
    my $ast  = parse('class Foo { field Int $id; method get() { return $id; } }');
    my $node = $ast->[0];
    isa_ok( $node, 'Brocken::AST::OOP::ClassDecl' );
    is( $node->name,                'Foo', 'class Foo' );
    is( scalar @{ $node->fields },  1,     'one field' );
    is( scalar @{ $node->methods }, 1,     'one method' );
    is( $node->methods->[0]->name,  'get', 'method get' );
};
subtest 'Ternary Operator' => sub {
    my $ast  = parse('$x ? 1 : 0;');
    my $node = $ast->[0];
    isa_ok( $node, 'Brocken::AST::Expr::Ternary' );
    is( $node->cond->name,  '$x', 'cond $x' );
    is( $node->then->value, 1,    'then 1' );
    is( $node->else->value, 0,    'else 0' );
};
subtest 'Method Call' => sub {
    my $ast  = parse('$obj->meth(1, 2);');
    my $node = $ast->[0];
    isa_ok( $node, 'Brocken::AST::Expr::MethodCall' );
    is( $node->object->name,     '$obj', 'invocant $obj' );
    is( $node->method,           'meth', 'method meth' );
    is( scalar @{ $node->args }, 2,      '2 args' );
};
done_testing;
