use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Brocken::AST;

class Brocken::Compiler::Optimizer {

    method optimize($builder) {
        my @instructions = $builder->instructions();
        return unless @instructions;
        $self->_tail_call_optimization( \@instructions );
        $self->_identify_leaf_functions( \@instructions );
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

    method _tail_call_optimization($insts) {
        for ( my $i = 0; $i < @$insts - 1; $i++ ) {
            my $curr = $insts->[$i];
            next unless $curr->{op} eq 'call_func' || $curr->{op} eq 'call_reg';

            # Look ahead for shadow_set + leave_func or just leave_func
            my $next_idx       = $i + 1;
            my $has_shadow_set = 0;
            if ( $next_idx < @$insts && $insts->[$next_idx]{op} && $insts->[$next_idx]{op} eq 'shadow_set' ) {
                $has_shadow_set = 1;
                $next_idx++;
            }

            # Skip labels or jmps that lead to the same leave_func
            while ( $next_idx < @$insts && $insts->[$next_idx]{op} && ( $insts->[$next_idx]{op} eq 'label' || $insts->[$next_idx]{op} eq 'jmp' ) ) {
                $next_idx++;
            }
            if ( $next_idx < @$insts && $insts->[$next_idx]{op} && $insts->[$next_idx]{op} eq 'leave_func' ) {
                my $leave = $insts->[$next_idx];
                if ( defined $leave->{args}[0] && defined $curr->{dest} && $leave->{args}[0] eq $curr->{dest} ) {

                    # Pattern matched: %res = call ...; [shadow_set ...;] leave_func %res
                    if ($has_shadow_set) {

                        # Move shadow_set BEFORE the tail call so it actually runs
                        my $ss = $insts->[ $i + 1 ];
                        $insts->[ $i + 1 ] = $curr;
                        $insts->[$i]       = $ss;
                        $curr->{op}        = ( $curr->{op} eq 'call_func' ) ? 'tail_call_func' : 'tail_call_reg';
                    }
                    else {
                        $curr->{op} = ( $curr->{op} eq 'call_func' ) ? 'tail_call_func' : 'tail_call_reg';
                    }
                    $leave->{op} = 'nop';
                }
            }
        }
    }

    method _identify_leaf_functions($insts) {
        my $current_enter = undef;
        my $is_leaf       = 1;
        for my $i (@$insts) {
            if ( $i->{op} eq 'enter_func' ) {
                $current_enter = $i;
                $is_leaf       = 1;
            }
            elsif ( $i->{op} eq 'leave_func' || $i->{op} eq 'tail_call_func' || $i->{op} eq 'tail_call_reg' ) {
                if ( $current_enter && $is_leaf ) {
                    $current_enter->{op} = 'enter_leaf_func';
                }
                $current_enter = undef;
            }
            elsif ($current_enter) {

                # Instructions that disqualify a leaf
                if ( $i->{op} =~ /^call_/ || $i->{op} =~ /^intrinsic_(print|alloc|sleep|read|write|open|close)/ ) {
                    $is_leaf = 0;
                }
            }
        }
    }

    method substitute_ast( $node, $var_name, $repl_node ) {
        if ( $node isa Brocken::AST::Expr::Var ) { return $node->name eq $var_name ? $repl_node : $node; }
        if ( $node isa Brocken::AST::Expr::BinOp ) {
            return Brocken::AST::Expr::BinOp->new(
                op    => $node->op,
                left  => $self->substitute_ast( $node->left,  $var_name, $repl_node ),
                right => $self->substitute_ast( $node->right, $var_name, $repl_node )
            );
        }
        if ( $node isa Brocken::AST::Expr::Const ) { return $node; }
        die 'Optimizer Error: Unhandled AST node ' . ref($node);
    }
}
1;
__END__

=pod

=head1 NAME

Brocken::Compiler::Optimizer - IR optimizer

=head1 SYNOPSIS

    my $optimizer = Brocken::Compiler::Optimizer->new();
    $optimizer->optimize($builder);

=head1 DESCRIPTION

Transforms the IR instruction sequence. Currently implements:

=over

=item Loop fusion (Futhark-style) - merges chained C<map { ... } map { ... }>
calls into a single loop pass.

=item Dead instruction elimination - removes instructions whose result is
never read.

=back

=head1 METHODS

=head2 optimize($builder)

  my $optimizer = Brocken::Compiler::Optimizer->new();
  $optimizer->optimize( $lowering->builder );

Modifies the builder's instruction list in place.

=cut

