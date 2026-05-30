use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Brocken::AST;

class Brocken::Compiler::Optimizer {
    field $opts : param : reader = {};
    ADJUST {
        # Setup defaults
        $opts = { escape => 1, tail_call => 1, leaf => 1, dce => 1, loop_fuse => 1, %$opts };
    }

    method escape_analysis($insts) {
        my %allocs;        # Map vreg -> Allocation Info
        my %escaped;       # Map vreg -> 1 (Escaped)
        my %const_vals;    # Map vreg -> Constant Numeric Value

        # Pass 1: Map all constants and find GC allocations
        for my $i ( 0 .. $#$insts ) {
            my $inst = $insts->[$i];
             if ( $inst->{op} eq 'constant' ) {
                $const_vals{ $inst->{dest} } = $inst->{args}[0];
            }
            if ( $inst->{op} eq 'call_func' && $inst->{args}[0] eq 'M_gc_alloc' ) {
                $allocs{ $inst->{dest} } = { idx => $i, size_raw_reg => $inst->{args}[1] };
            }
        }

        # Pass 2: Analyze variable uses across the entire IR sequence
        for my $i ( 0 .. $#$insts ) {
            my $inst = $insts->[$i];
            my @uses;
            if ( $inst->{args} ) {
                @uses = grep { defined && !ref($_) && /^%/ } @{ $inst->{args} };
            }
            push @uses, $inst->{reg} if $inst->{op} eq 'cond_br' && $inst->{reg} =~ /^%/;
            for my $u (@uses) {
                next unless exists $allocs{$u};

                # Escape Conditions:
                # 1. Passed as an argument to a function or method call
                if ( $inst->{op} =~ /^call_/ || $inst->{op} =~ /^tail_call_/ ) {
                    $escaped{$u} = 1;
                }

                # 2. Returned from the current subroutine
                elsif ( $inst->{op} eq 'leave_func' ) {
                    $escaped{$u} = 1;
                }

                # 3. Stored in a global/package variable (Isolate Context)
                elsif ( $inst->{op} eq 'store_iso_disp' ) {
                    $escaped{$u} = 1;
                }

                # 4. Stored inside another object (as the stored value at argument 2)
                elsif ( $inst->{op} eq 'store_mem_disp' ) {
                    if ( defined $inst->{args}[2] && $inst->{args}[2] eq $u ) {
                        $escaped{$u} = 1;
                    }
                }
            }
        }

        # Pass 3: Mutate non-escaping allocations into static stack allocations
        for my $v ( keys %allocs ) {
            next if $escaped{$v};
            my $size_reg = $allocs{$v}{size_raw_reg};
            my $size_val = undef;
            if ( defined $size_reg ) {
                if ( $size_reg !~ /^%/ ) {
                    $size_val = $size_reg;
                }
                elsif ( exists $const_vals{$size_reg} ) {
                    $size_val = $const_vals{$size_reg};
                }
            }

            # If the size is not statically known, we cannot stack allocate it
            next unless defined $size_val;
            my $alloc_inst = $insts->[ $allocs{$v}{idx} ];
            $alloc_inst->{op} = 'stack_alloc';
            my $size_raw = $size_val & 0xFFFFFFFFFF;

            # Statically align and compute total size (including 8-byte header)
            my $aligned_sz = ( $size_raw + 15 ) & -8;
            $alloc_inst->{args} = [ $size_val, $aligned_sz ];
        }
    }

    method optimize($builder) {
        my @instructions = $builder->instructions();
        return unless @instructions;
        $self->_tail_call_optimization( \@instructions )  if $opts->{tail_call};
        $self->_identify_leaf_functions( \@instructions ) if $opts->{leaf};
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
            if ( $opts->{dce} ) {
                for my $i (@instructions) {
                    next if $i->{op} eq 'nop';
                    next unless defined $i->{dest};
                    next if $i->{op} =~ /^(?:call_|tail_call_|store_|intrinsic_|shadow_|mark_try_|leave_func)/;
                    if ( ( $use_count{ $i->{dest} } // 0 ) == 0 ) {
                        $i->{op} = 'nop';
                        $changed = 1;
                    }
                }
            }
            if ( $opts->{loop_fuse} ) {
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
            }
            @instructions = grep { $_->{op} ne 'nop' } @instructions;
        }
        $builder->set_instructions(@instructions);
    }

    method _tail_call_optimization($insts) {
        for ( my $i = 0; $i < @$insts - 1; $i++ ) {
            my $curr = $insts->[$i];
            next unless $curr->{op} eq 'call_func' || $curr->{op} eq 'call_reg';
            my $next_idx       = $i + 1;
            my $has_shadow_set = 0;
            if ( $next_idx < @$insts && $insts->[$next_idx]{op} && $insts->[$next_idx]{op} eq 'shadow_set' ) {
                $has_shadow_set = 1;
                $next_idx++;
            }
            while ( $next_idx < @$insts && $insts->[$next_idx]{op} && ( $insts->[$next_idx]{op} eq 'label' || $insts->[$next_idx]{op} eq 'jmp' ) ) {
                $next_idx++;
            }
            if ( $next_idx < @$insts && $insts->[$next_idx]{op} && $insts->[$next_idx]{op} eq 'leave_func' ) {
                my $leave = $insts->[$next_idx];
                if ( defined $leave->{args}[0] && defined $curr->{dest} && $leave->{args}[0] eq $curr->{dest} ) {
                    if ($has_shadow_set) {
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
            elsif ( $i->{op} eq 'leave_func' ) {
                if ( $current_enter && $is_leaf ) {
                    $current_enter->{op} = 'enter_leaf_func';
                }
                $current_enter = undef;
            }
            elsif ( $i->{op} eq 'tail_call_func' || $i->{op} eq 'tail_call_reg' ) {
                $current_enter = undef;
            }
            elsif ($current_enter) {
                if ( $i->{op} =~ /^call_/ || $i->{op} =~ /^intrinsic_(print|print_stderr|alloc|sleep|read|write|open|close)/ ) {
                    $is_leaf = 0;
                }
            }
        }
    }

    method coverage_report($builder) {
        my @insts = $builder->instructions();
        return {} unless @insts;
        my %label_idx;
        for my $i ( 0 .. $#insts ) {
            $label_idx{ $insts[$i]{name} } = $i if $insts[$i]{op} eq 'label';
        }
        my @entry = grep { $insts[$_]{op} =~ /^enter_func/ } 0 .. $#insts;
        return {} unless @entry;
        my %reachable;
        my @work = @entry;
        while (@work) {
            my $idx = pop @work;
            next if $reachable{$idx}++ || $idx > $#insts;
            my $op = $insts[$idx]{op};
            next if $op eq 'leave_func' || $op eq 'nop';
            if ( $op eq 'jmp' ) {
                my $t = $label_idx{ $insts[$idx]{target} };
                push @work, $t if defined $t;
            }
            elsif ( $op eq 'cond_br' ) {
                my $tt = $label_idx{ $insts[$idx]{true_l} };
                my $ft = $label_idx{ $insts[$idx]{false_l} };
                push @work, $tt if defined $tt;
                push @work, $ft if defined $ft;
            }
            else {
                push @work, $idx + 1 if $idx + 1 <= $#insts;
            }
        }
        my ( %op_total, %op_reach );
        for my $i ( 0 .. $#insts ) {
            $op_total{ $insts[$i]{op} }++;
            $op_reach{ $insts[$i]{op} }++ if $reachable{$i};
        }
        return {
            total_insts  => scalar(@insts),
            reachable    => scalar( keys %reachable ),
            unreachable  => scalar(@insts) - scalar( keys %reachable ),
            opcode_total => \%op_total,
            opcode_reach => \%op_reach,
        };
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

    method insert_coverage_probes($insts) {
        my $probe_id = 0;
        my @new;
        for my $i ( 0 .. $#$insts ) {
            my $inst = $insts->[$i];
            if ( $inst->{op} eq 'label' || $inst->{op} eq 'source_loc' ) {
                push @new, { op => 'coverage_probe', args => [ $probe_id++ ] };
            }
            push @new, $inst;
        }
        @$insts = @new;
        return $probe_id;
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

