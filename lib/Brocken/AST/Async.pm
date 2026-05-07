package Brocken::AST::Async {
    use v5.40;
    use feature 'class';
    no warnings 'experimental::class';
    #
    class Brocken::AST::Async::FiberBlock : isa(Brocken::AST::Node) { field $params : param : reader = []; field $body : param : reader; }

    class Brocken::AST::Async::Yield : isa(Brocken::AST::Node) { field $expr : param : reader; }
}
1;
