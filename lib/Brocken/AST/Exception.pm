package Brocken::AST::Exception {
    use v5.40;
    use feature 'class';
    no warnings 'experimental::class';
    #
    class Brocken::AST::Exception::TryCatch : isa(Brocken::AST::Node) {
        field $try_block     : param : reader;
        field $catch_var     : param : reader;
        field $catch_block   : param : reader;
        field $finally_block : param : reader = undef;
    }

    class Brocken::AST::Exception::Die : isa(Brocken::AST::Node) {
        field $exception : param : reader;    # Not defined yet
    }
}
1;
