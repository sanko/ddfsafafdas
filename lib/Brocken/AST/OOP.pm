package Brocken::AST::OOP {
    use v5.40;
    use feature 'class';
    no warnings 'experimental::class';
    #
    class Brocken::AST::OOP::ClassDecl : isa(Brocken::AST::Node)
    { field $name : param : reader; field $fields : param : reader; field $methods : param : reader; }

    class Brocken::AST::OOP::FieldDecl : isa(Brocken::AST::Node) { field $name : param : reader; field $type : param : reader; }

    class Brocken::AST::OOP::Method : isa(Brocken::AST::Node)
    { field $name : param : reader; field $params : param : reader; field $body : param : reader; }

    class Brocken::AST::OOP::MethodCall : isa(Brocken::AST::Node)
    { field $invocant : param : reader; field $name : param : reader; field $args : param : reader; }

    class Brocken::AST::OOP::AnonSub : isa(Brocken::AST::Node) { field $params : param : reader; field $body : param : reader; }
}
1;
__END__

=pod

=head1 NAME

Brocken::AST::OOP - OOP AST node classes

=head1 DESCRIPTION

Defines OOP node types:

=over

=item ClassDecl - class declarations with fields and methods

=item FieldDecl - field declarations within a class

=item Method - method / sub declarations with params and body

=item MethodCall - $obj->method(...)

=item AnonSub - sub (...) { ... }

=back

All classes inherit from Brocken::AST::Node.

=cut
1;
