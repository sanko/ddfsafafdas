package Brocken {
    use v5.40;
    use utf8;
    use feature 'class';
    no warnings 'portable', 'experimental::class';
    use Brocken::AST;
    use Brocken::Compiler;
    use Brocken::Codegen;
    use Brocken::Lexer;
    use Brocken::Parser;
    use Brocken::IR;

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
            return $symbols{$name} = Brocken::Symbol->new(
                name         => $name,
                type         => $type,
                is_state     => $is_state,
                state_idx    => $state_idx,
                stack_offset => $stack_offset
            );
        }
        method resolve($name) { return $symbols{$name} // ( $parent ? $parent->resolve($name) : undef ); }
    }
};
1;
