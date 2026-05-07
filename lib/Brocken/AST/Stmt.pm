package Brocken::AST::Stmt {
    use v5.40;
    use feature 'class';
    no warnings 'experimental::class';
    #
    class Brocken::AST::Stmt::Block : isa(Brocken::AST::Node) { field $statements : param : reader; }

    class Brocken::AST::Stmt::VarDecl : isa(Brocken::AST::Node)
    { field $name : param : reader; field $type : param : reader; field $value : param : reader; }

    class Brocken::AST::Stmt::StateDecl : isa(Brocken::AST::Node)
    { field $name : param : reader; field $type : param : reader; field $value : param : reader; }

    class Brocken::AST::Stmt::Assignment : isa(Brocken::AST::Node) { field $name : param : reader; field $value : param : reader; }

    class Brocken::AST::Stmt::If : isa(Brocken::AST::Node)
    { field $condition : param : reader; field $then_block : param : reader; field $else_block : param : reader = undef; }

    class Brocken::AST::Stmt::While : isa(Brocken::AST::Node) { field $condition : param : reader; field $body : param : reader; }

    class Brocken::AST::Stmt::Return : isa(Brocken::AST::Node) { field $expr : param : reader; }

    class Brocken::AST::Stmt::Exit : isa(Brocken::AST::Node) { field $expr : param : reader; }

    class Brocken::AST::Stmt::Map : isa(Brocken::AST::Node) { field $expr : param : reader; field $source : param : reader; }

    class Brocken::AST::Stmt::Defer : isa(Brocken::AST::Node) { field $block : param : reader;  }
}
1;
