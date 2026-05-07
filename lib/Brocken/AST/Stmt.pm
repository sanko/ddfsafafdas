package Brocken::AST::Stmt {
    use v5.40;
    use feature 'class';
    no warnings 'experimental::class';
    #
    class Brocken::AST::Block : isa(Brocken::AST::Node) { field $statements : param : reader; }

    class Brocken::AST::VarDecl : isa(Brocken::AST::Node)
    { field $name : param : reader; field $type : param : reader; field $value : param : reader; }

    class Brocken::AST::StateDecl : isa(Brocken::AST::Node)
    { field $name : param : reader; field $type : param : reader; field $value : param : reader; }

    class Brocken::AST::Assignment : isa(Brocken::AST::Node) { field $name : param : reader; field $value : param : reader; }

    class Brocken::AST::If : isa(Brocken::AST::Node)
    { field $condition : param : reader; field $then_block : param : reader; field $else_block : param : reader = undef; }

    class Brocken::AST::While : isa(Brocken::AST::Node) { field $condition : param : reader; field $body : param : reader; }

    class Brocken::AST::Return : isa(Brocken::AST::Node) { field $expr : param : reader; }

    class Brocken::AST::Exit : isa(Brocken::AST::Node) { field $expr : param : reader; }

    class Brocken::AST::Map : isa(Brocken::AST::Node) { field $expr : param : reader; field $source : param : reader; }
}
1;
