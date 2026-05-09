package Brocken::AST {
    use v5.40;
    use Brocken::AST::Node;
    use Brocken::AST::Expr;
    use Brocken::AST::Stmt;
    use Brocken::AST::OOP;
    use Brocken::AST::Async;
}
1;
__END__

=pod

=head1 NAME

Brocken::AST - Aggregates all AST node classes

=head1 DESCRIPTION

Loads AST::Node, AST::Expr, AST::Stmt, AST::OOP, and AST::Async. Also defines several core AST node types inline:
AnonSub, AnonCall, BinOp, Const, Var, VarDecl, StateDecl, Assignment, Return, Exit, Yield, FiberBlock, Block, Call, If,
While, Map, Method, ArrayLiteral, IndexExpr, ClassDecl, FieldDecl, MethodCall, UnaryOp, Ternary.

All classes inherit from Brocken::AST::Node.

=cut
1;
