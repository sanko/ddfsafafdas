package Brocken {
    use v5.40;
    use utf8;
    use feature 'class';
    no warnings 'portable', 'experimental::class';
    use Brocken::AST;
    use Brocken::Compiler;
    use Brocken::Compiler::Lowering;
    use Brocken::Compiler::Optimizer;
    use Brocken::Compiler::DataSegment;
    use Brocken::Codegen;
    use Brocken::Lexer;
    use Brocken::Parser;
    use Brocken::IR;

    package Brocken::Util {
        sub align ( $val, $align ) { ( $val + $align - 1 ) & ~( $align - 1 ) }
    }
};
1;
__END__

=pod

=head1 NAME

Brocken - Top-level package for the Brocken compiler

=head1 SYNOPSIS

  use Brocken;

=head1 DESCRIPTION

Loads all compiler components and defines base types used throughout:

=over

=item Brocken::Symbol

Metadata for a single variable: name, type, is_state, state_idx, stack_offset.

=item Brocken::Scope

Lexical scope with parent chain. C<define()> registers a symbol (dies on redeclaration). C<resolve()> looks up a symbol
in the current scope and walks up the parent chain.

=item Brocken::Util::align

Aligns a value upward to the given alignment boundary.

=back

=cut
1;
