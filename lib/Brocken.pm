package Brocken {
    use v5.40;
    use utf8;
    use feature 'class';
    no warnings 'portable', 'experimental::class';
    #
    use Brocken::AST;
    use Brocken::Compiler;
    use Brocken::Codegen;
    use Brocken::Lexer;
    use Brocken::Parser;
    use Brocken::IR;

    class Brocken::Symbol {
        field $name : param : reader;
        field $type : param : reader;

        # For unboxed types (Int, String)
        field $ssa_reg;

        # For boxed types (Any)
        field $ssa_tag_reg;
        field $ssa_payload_reg;
        method ssa_reg( $val = undef ) { $ssa_reg = $val if defined $val; return $ssa_reg; }

        method set_any( $tag, $payload ) {
            $ssa_tag_reg     = $tag;
            $ssa_payload_reg = $payload;
        }
        method get_any() { return ( $ssa_tag_reg, $ssa_payload_reg ); }
    }

    class Brocken::Scope {
        field $parent : param : reader = undef;
        field %symbols;

        method define( $name, $type ) {
            die "Semantic Error: Redeclaration of $name\n" if exists $symbols{$name};
            return $symbols{$name} = Brocken::Symbol->new( name => $name, type => $type );
        }
        method resolve($name) { return $symbols{$name} // ( $parent ? $parent->resolve($name) : undef ); }
    }
};
1;
