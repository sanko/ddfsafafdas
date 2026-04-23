package Brocken::AST::Node {
    use v5.40;
    use utf8;
    use feature 'class';
    no warnings 'portable', 'experimental::class';

    class Brocken::AST::Node {
        method dump {'Node'}
    }

    class Brocken::AST::BinOp : isa(Brocken::AST::Node) {
        field $op    : param : reader;
        field $left  : param : reader;
        field $right : param : reader;
        method dump { "(" . $left->dump . " " . $op . " " . $right->dump . ")" }
    }

    class Brocken::AST::Const : isa(Brocken::AST::Node) {
        field $value : param : reader;
        field $type  : param : reader;
        method dump { $type eq 'String' ? qq{"$value"} : $value }
    }

    class Brocken::AST::Var : isa(Brocken::AST::Node) {
        field $name : param : reader;
        method dump {$name}
    }

    class Brocken::AST::VarDecl : isa(Brocken::AST::Node)
    { field $name : param : reader; field $type : param : reader; field $value : param : reader; }

    class Brocken::AST::StateDecl : isa(Brocken::AST::Node)
    { field $name : param : reader; field $type : param : reader; field $value : param : reader; }

    class Brocken::AST::Assignment : isa(Brocken::AST::Node) { field $name : param : reader; field $value : param : reader; }

    class Brocken::AST::Return : isa(Brocken::AST::Node) { field $expr : param : reader; }

    class Brocken::AST::Block : isa(Brocken::AST::Node) { field $statements : param : reader; }

    class Brocken::AST::Call : isa(Brocken::AST::Node) { field $name : param : reader; field $args : param : reader; }

    class Brocken::AST::If : isa(Brocken::AST::Node)
    { field $condition : param : reader; field $then_block : param : reader; field $else_block : param : reader = undef; }

    class Brocken::AST::While : isa(Brocken::AST::Node) { field $condition : param : reader; field $body : param : reader; }

    class Brocken::AST::Map : isa(Brocken::AST::Node) { field $expr : param : reader; field $source : param : reader; }

    class Brocken::AST::Method : isa(Brocken::AST::Node)
    { field $name : param : reader; field $params : param : reader; field $body : param : reader; }

    class Brocken::AST::ArrayLiteral : isa(Brocken::AST::Node) { field $elements : param : reader; }

    class Brocken::AST::IndexExpr : isa(Brocken::AST::Node) { field $source : param : reader; field $index : param : reader; }
};
1;
