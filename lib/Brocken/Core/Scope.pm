package Brocken::Core::Scope {
    use v5.40;
    use utf8;
    use feature 'class';
    no warnings 'portable', 'experimental::class';
    use Brocken::Core::Symbol;

    class Brocken::Core::Scope {
        field $parent : param : reader = undef;
        field %symbols;

        method define( $name, $type, $is_state = 0, $state_idx = undef, $stack_offset = undef, $shadow_offset = undef, $isolate_offset = undef ) {
            die "Semantic Error: Redeclaration of $name\n" if exists $symbols{$name};
            return $symbols{$name} = Brocken::Core::Symbol->new(
                name           => $name,
                type           => $type,
                is_state       => $is_state,
                state_idx      => $state_idx,
                stack_offset   => $stack_offset,
                shadow_offset  => $shadow_offset,
                isolate_offset => $isolate_offset
            );
        }
        method has_local_symbol($name) { return exists $symbols{$name}; }
        method resolve($name)          { return $symbols{$name} // ( $parent ? $parent->resolve($name) : undef ); }
    }
}
1;
