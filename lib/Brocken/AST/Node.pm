use v5.40;
use feature 'class';
no warnings 'experimental::class';
#
class Brocken::AST::Node {
    field $line : param : reader = 0;
    field $col  : param : reader = 0;
    method dump { ( ref $self ) =~ s/.*:://r }
}
1;
__END__

=pod

=head1 NAME

Brocken::AST::Node - Base class for all AST nodes

=head1 SYNOPSIS

    # In a subclass
    class Brocken::AST::Expr::Const : isa(Brocken::AST::Node) { ... }

    my $node = Brocken::AST::Expr::Const->new( line => 10, col => 5, ... );
    say $node->line; # 10
    say $node->dump; # Const

=head1 DESCRIPTION

Provides a common base for all nodes in the Brocken Abstract Syntax Tree. Stores source location information used for
error reporting and debug symbols.

=head1 FIELDS

=over

=item line

The source line number where this node begins.

=item col

The source column number where this node begins.

=back

=head1 METHODS

=head2 dump

Returns the short class name of the node (e.g. 'Const', 'BinOp', 'If'), primarily used for debugging and IR output.

=cut
1;
