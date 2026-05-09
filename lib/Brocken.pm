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

    class Brocken::Symbol {
        field $name         : param : reader;
        field $type         : param : reader;
        field $is_state     : param : reader = 0;
        field $state_idx    : param : reader = undef;
        field $stack_offset : param : reader = undef;
    }

    class Brocken::Scope {
        field $parent : param : reader = undef;
        field %symbols;

        method define( $name, $type, $is_state = 0, $state_idx = undef, $stack_offset = undef ) {
            die "Semantic Error: Redeclaration of $name\n" if exists $symbols{$name};
            return $symbols{$name}
                = Brocken::Symbol->new( name => $name, type => $type, is_state => $is_state, state_idx => $state_idx, stack_offset => $stack_offset );
        }
        method resolve($name) { return $symbols{$name} // ( $parent ? $parent->resolve($name) : undef ); }
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
