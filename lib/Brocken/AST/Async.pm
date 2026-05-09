package Brocken::AST::Async {
    use v5.40;
    use feature 'class';
    no warnings 'experimental::class';
    #
    class Brocken::AST::Async::FiberBlock : isa(Brocken::AST::Node) { field $params : param : reader = []; field $body : param : reader; }

    class Brocken::AST::Async::Yield : isa(Brocken::AST::Node) { field $expr : param : reader; }
}
1;
__END__

=pod

=head1 NAME

Brocken::AST::Async - Async/concurrency AST node classes

=head1 DESCRIPTION

Defines async node types:

=over

=item FiberBlock - fiber { ... } with optional params

=item Yield - yield expr

=back

All classes inherit from Brocken::AST::Node.

=cut
1;
