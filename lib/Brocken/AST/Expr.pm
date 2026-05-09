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

    class Brocken::AST::Expr::IndexExpr : isa(Brocken::AST::Node) { field $source : param : reader; field $index : param : reader; }
}
1;
