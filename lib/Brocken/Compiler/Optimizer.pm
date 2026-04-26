package Brocken::Compiler::Optimizer {
    use v5.40;
    use utf8;
    use feature 'class';
    no warnings 'portable', 'experimental::class';
    use Brocken::AST;

    class Brocken::Compiler::Optimizer {

        method optimize($builder) {
            my @instructions = $builder->instructions();
            return unless @instructions;
            my $changed = 1;
            while ($changed) {
                $changed = 0;
                my ( %def, %use_count, %shadow_map );
                for my $i (@instructions) {
                    next                    if $i->{op} eq 'nop';
                    $def{ $i->{dest} } = $i if defined $i->{dest};
                    if ( $i->{args} ) {
                        for my $arg ( @{ $i->{args} } ) { $use_count{$arg}++ if $arg && !ref($arg) && $arg =~ /^%/; }
                    }
                    $use_count{ $i->{reg} }++ if $i->{op} eq 'cond_br' && $i->{reg};
                    if ( $i->{op} eq 'shadow_push' ) { $shadow_map{ $i->{args}[0] } = $i; }
                }
                for my $i (@instructions) {
                    next unless $i->{op} eq 'map_op';
                    my $src_reg = $i->{args}[0];
                    my $prev    = $def{$src_reg};
                    if ( $prev && $prev->{op} eq 'map_op' && ( $use_count{$src_reg} // 0 ) <= 2 ) {
                        $i->{args}[1] = $self->substitute_ast( $i->{args}[1], '$_', $prev->{args}[1] );
                        $i->{args}[0] = $prev->{args}[0];
                        $prev->{op}   = 'nop';
                        if ( $shadow_map{$src_reg} ) { $shadow_map{$src_reg}->{op} = 'nop'; }
                        $changed = 1;
                    }
                }
                @instructions = grep { $_->{op} ne 'nop' } @instructions;
            }
            $builder->set_instructions(@instructions);
        }

        method substitute_ast( $node, $var_name, $repl_node ) {
            if ( $node isa Brocken::AST::Var ) { return $node->name eq $var_name ? $repl_node : $node; }
            if ( $node isa Brocken::AST::BinOp ) {
                return Brocken::AST::BinOp->new(
                    op    => $node->op,
                    left  => $self->substitute_ast( $node->left,  $var_name, $repl_node ),
                    right => $self->substitute_ast( $node->right, $var_name, $repl_node )
                );
            }
            if ( $node isa Brocken::AST::Const ) { return $node; }
            die 'Optimizer Error: Unhandled AST node ' . ref($node);
        }
    }
}
1;
