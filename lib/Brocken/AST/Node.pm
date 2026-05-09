package Brocken::AST::Node {
    use v5.40;
    use feature 'class';
    no warnings 'experimental::class';
    #
    class Brocken::AST::Node {
        field $line : param : reader = 0;
        field $col  : param : reader = 0;
        method dump { ( ref $self ) =~ s/.*:://r }
    }
}
1;
__END__

=pod

=head1 NAME

Brocken::AST::Node - Base class for all AST nodes

=head1 DESCRIPTION

Provides a C<dump> method that returns the short class name (stripping the package prefix). All AST expression,
statement, OOP, and async nodes inherit from this class.

=cut
1;
