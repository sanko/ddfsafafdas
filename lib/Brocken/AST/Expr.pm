package Brocken::AST::Expr {
    use v5.40;
    use feature 'class';
    no warnings 'experimental::class';
    #
    class Brocken::AST::Expr::Const : isa(Brocken::AST::Node) { field $value : param : reader; field $type : param : reader; }

    class Brocken::AST::Expr::Var : isa(Brocken::AST::Node) { field $name : param : reader; }

    class Brocken::AST::Expr::BinOp : isa(Brocken::AST::Node)
    { field $op : param : reader; field $left : param : reader; field $right : param : reader; }

    class Brocken::AST::Expr::UnaryOp : isa(Brocken::AST::Node) { field $op : param : reader; field $expr : param : reader; }

    class Brocken::AST::Expr::Ternary : isa(Brocken::AST::Node)
    { field $cond : param : reader; field $then : param : reader; field $else : param : reader; }

    class Brocken::AST::Expr::Call : isa(Brocken::AST::Node) { field $name : param : reader; field $args : param : reader; }

    class Brocken::AST::Expr::AnonCall : isa(Brocken::AST::Node) { field $invocant : param : reader; field $args : param : reader; }

    class Brocken::AST::Expr::ArrayLiteral : isa(Brocken::AST::Node) { field $elements : param : reader; }

    class Brocken::AST::Expr::TupleLiteral : isa(Brocken::AST::Node) { field $elements : param : reader; }

    class Brocken::AST::Expr::HashLiteral : isa(Brocken::AST::Node) { field $pairs : param : reader; }

    class Brocken::AST::Expr::IndexExpr : isa(Brocken::AST::Node) { field $source : param : reader; field $index : param : reader; }

    class Brocken::AST::Expr::MethodCall : isa(Brocken::AST::Node)
    { field $object : param : reader; field $method : param : reader; field $args : param : reader; }

    class Brocken::AST::Expr::Exists : isa(Brocken::AST::Node) { field $expr : param : reader; }

    class Brocken::AST::Expr::Delete : isa(Brocken::AST::Node) { field $expr : param : reader; }
}
1;
__END__

=pod

=head1 NAME

Brocken::AST::Expr - Expression AST node classes

=head1 DESCRIPTION

Defines expression node types:

=over

=item Const - literal values (Int, String, Class)

=item Var - variable references

=item BinOp - binary operators (+, ==, &&, etc.)

=item UnaryOp - unary operators (!)

=item Ternary - cond ? then : else

=item Call - function calls (say, print, user functions)

=item AnonCall - anonymous sub invocation ($f->())

=item ArrayLiteral - array constructors ([1, 2, 3])

=item IndexExpr - array indexing (@arr[0])

=back

All classes inherit from Brocken::AST::Node.

=cut
1;
