package Brocken::AST::Expr {
    use v5.40;
    use feature 'class';
    no warnings 'experimental::class';
    #
    class Brocken::AST::Const : isa(Brocken::AST::Node) { field $value : param : reader; field $type : param : reader; }

    class Brocken::AST::Var : isa(Brocken::AST::Node) { field $name : param : reader; }

    class Brocken::AST::BinOp : isa(Brocken::AST::Node) { field $op : param : reader; field $left : param : reader; field $right : param : reader; }

    class Brocken::AST::UnaryOp : isa(Brocken::AST::Node) { field $op : param : reader; field $expr : param : reader; }

    class Brocken::AST::Ternary : isa(Brocken::AST::Node)
    { field $cond : param : reader; field $then : param : reader; field $else : param : reader; }

    class Brocken::AST::Call : isa(Brocken::AST::Node) { field $name : param : reader; field $args : param : reader; }

    class Brocken::AST::AnonCall : isa(Brocken::AST::Node) { field $invocant : param : reader; field $args : param : reader; }

    class Brocken::AST::ArrayLiteral : isa(Brocken::AST::Node) { field $elements : param : reader; }

    class Brocken::AST::IndexExpr : isa(Brocken::AST::Node) { field $source : param : reader; field $index : param : reader; }
}
1;
