package Brocken::Compiler {
    use v5.40;
    use utf8;
    use feature 'class';
    no warnings 'portable', 'experimental::class';

    class Brocken::Compiler::Lowering {
        use constant { TAG_INT => 0, TAG_STR => 1, TAG_ARR => 2, TAG_OBJ => 3 };
        field $builder : reader : param = Brocken::IR::Builder->new();
        field $data_segment : param;
        field $current_scope = Brocken::Scope->new();
        field $state_count   = 0;
method inject_runtime() {
    # --- M_gc_alloc ---
    $builder->emit_label('M_gc_alloc');
    $builder->emit('enter_func', 'void', []);
    my $size = $builder->emit('get_arg', 'i64', [0]);
    my $alloc_ptr = $builder->emit('load_iso_disp', 'ptr', [0]);
    my $limit_ptr = $builder->emit('load_iso_disp', 'ptr', [8]);
    my $new_alloc = $builder->emit('add', 'ptr', [$alloc_ptr, $size]);
    my $is_full   = $builder->emit('cmp_gt', 'Int', [$new_alloc, $limit_ptr]);
    my $l_fast = $builder->new_label(); my $l_slow = $builder->new_label();
    $builder->emit_cond_br($is_full, $l_slow, $l_fast);
    $builder->emit_label($l_fast);
    $builder->emit('store_iso_disp', 'void', [0, $new_alloc]);
    $builder->emit('leave_func', 'void', [$alloc_ptr]);
    $builder->emit_label($l_slow);
    my $new_region = $builder->emit('sys_alloc', 'ptr', [65536]);
    my $new_limit  = $builder->emit('add', 'ptr', [$new_region, 65536]);
    my $res_alloc  = $builder->emit('add', 'ptr', [$new_region, $size]);
    $builder->emit('store_iso_disp', 'void', [0, $res_alloc]);
    $builder->emit('store_iso_disp', 'void', [8, $new_limit]);
    $builder->emit('leave_func', 'void', [$new_region]);

# --- M_print_int (Corrected Control Flow) ---
    $builder->emit_label('M_print_int');
    $builder->emit('enter_func', 'void', []);
    my $n = $builder->emit('get_arg', 'i64', [0]);

    my $l_z = $builder->new_label();
    my $l_not_z = $builder->new_label();

    # Check if N == 0
    $builder->emit_cond_br($builder->emit('cmp_eq', 'Int', [$n, 0]), $l_z, $l_not_z);

    # ZERO PATH
    $builder->emit_label($l_z);
    $builder->emit('builtin_print_char', 'void', [48]); # Ascii '0'
    $builder->emit('leave_func', 'void', [0]);

    # NON-ZERO PATH
    $builder->emit_label($l_not_z);
    my $count = $builder->emit('constant', 'i64', [0]);
    my $l_loop_push = $builder->new_label();
    my $l_loop_pop  = $builder->new_label();

    # Push Loop
    $builder->emit_label($l_loop_push);
    my $digit = $builder->emit('mod', 'i64',[$n, 10]);
    $builder->emit('push', 'void',[$builder->emit('add', 'i64', [$digit, 48])]);
    $count = $builder->emit('add', 'i64', [$count, 1], $count);
    $builder->emit('div', 'i64',[$n, 10], $n);
    $builder->emit_cond_br($builder->emit('cmp_gt', 'Int', [$n, 0]), $l_loop_push, $l_loop_pop);

    # Pop Loop
    my $l_end = $builder->new_label();
    $builder->emit_label($l_loop_pop);
    $builder->emit('builtin_print_char', 'void', [$builder->emit('pop', 'i64', [])]);
    $count = $builder->emit('sub', 'i64', [$count, 1], $count);
    $builder->emit_cond_br($builder->emit('cmp_gt', 'Int',[$count, 0]), $l_loop_pop, $l_end);

    $builder->emit_label($l_end);
    $builder->emit('leave_func', 'void', [0]);
}

        method lower_program($nodes) {

            # --- 1. EMIT THE ENTRY JUMP FIRST ---
            # This must be the very first instruction in the .text segment
            $builder->emit_jump('L_MAIN_START');

            # --- 2. THEN INJECT RUNTIME & METHODS ---
            $self->inject_runtime();
            my @methods = grep { $_ isa Brocken::AST::Method } @$nodes;
            my @stmts   = grep { !( $_ isa Brocken::AST::Method ) } @$nodes;
            for my $m (@methods) {
                $builder->emit_label( "M_" . $m->name );
                $builder->emit( 'enter_func', 'void', [] );
                $current_scope = Brocken::Scope->new( parent => $current_scope );
                my $arg_idx = 0;
                for my $p ( @{ $m->params } ) {
                    my $reg = $builder->emit( 'get_arg', 'i64', [ $arg_idx++ ] );
                    $current_scope->define( $p->{name}, $p->{type} )->ssa_reg($reg);
                }
                $self->lower_block( $m->body->statements );
                $current_scope = $current_scope->parent;
            }

            # --- 3. MAIN ENTRY POINT ---
            $builder->emit_label('L_MAIN_START');
            $builder->emit( 'enter_func', 'void', [] );

            # (Initialize Isolate Context - r14/x27)
            my $c1024   = $builder->emit( 'constant',  'i64', [1024] );
            my $iso_reg = $builder->emit( 'sys_alloc', 'ptr', [$c1024] );
            $builder->emit( 'set_isolate_ctx', 'void', [$iso_reg] );
            my $c64k        = $builder->emit( 'constant',  'i64', [65536] );
            my $init_region = $builder->emit( 'sys_alloc', 'ptr', [$c64k] );
            my $init_limit  = $builder->emit( 'add',       'ptr', [ $init_region, $c64k ] );
            $builder->emit( 'store_iso_disp', 'void', [ 0, $init_region ] );
            $builder->emit( 'store_iso_disp', 'void', [ 8, $init_limit ] );
            my $state_block = $builder->emit( 'sys_alloc', 'ptr', [$c64k] );
            $builder->emit( 'store_iso_disp', 'void', [ 16, $state_block ] );
            $self->lower_block( \@stmts );
            $builder->emit( 'exit_program', 'void', [0] );
        }

        method lower_block($statements) {
            my ( $reg, $type );
            for my $stmt (@$statements) { ( $reg, $type ) = $self->lower($stmt); }
            return ( $reg, $type );
        }

        method lower($node) {
            if ( $node isa Brocken::AST::Block ) {
                $current_scope = Brocken::Scope->new( parent => $current_scope );
                my @res = $self->lower_block( $node->statements );
                $current_scope = $current_scope->parent;
                return @res;
            }
            if ( $node isa Brocken::AST::Const ) {
                if ( $node->type eq 'String' ) {
                    my $reg = $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string( $node->value ) ] );
                    $builder->emit( 'shadow_push', 'void', [$reg] );
                    return ( $reg, 'String' );
                }
                return ( $builder->emit( 'constant', 'i64', [ $node->value ] ), 'Int' );
            }
            if ( $node isa Brocken::AST::Var ) {
                my $sym = $current_scope->resolve( $node->name ) // die "Undeclared " . $node->name . "\n";
                if ($sym->is_state) {
                    my $sb  = $builder->emit( 'load_iso_disp', 'ptr', [16] );
                    my $res = $builder->emit( 'load_mem_disp', $sym->type, [ $sb, 4096 + ( $sym->state_idx * 8 ) ] );
                    return ($res, $sym->type);
                }
                return ( $sym->ssa_reg, $sym->type );
            }
            if ( $node isa Brocken::AST::StateDecl ) {
                my $idx    = $state_count++;
                my $sym    = $current_scope->define( $node->name, $node->type, 1, $idx );
                my $l_init = $builder->new_label();
                my $l_done = $builder->new_label();
                my $sb     = $builder->emit( 'load_iso_disp', 'ptr', [16] );
                my $guard  = $builder->emit( 'load_mem_byte', 'Int', [ $sb, $idx ] );
                $builder->emit_cond_br( $guard, $l_done, $l_init );
                $builder->emit_label($l_init);
                my ( $v_reg, $v_typ ) = $self->lower( $node->value );
                my $one = $builder->emit( 'constant', 'Int', [1] );
                $builder->emit( 'store_mem_byte', 'void', [ $sb, $idx, $one ] );
                $builder->emit( 'store_mem_disp', 'void', [ $sb, 4096 + ( $idx * 8 ), $v_reg ] );
                $builder->emit_jump($l_done);
                $builder->emit_label($l_done);
                my $res = $builder->emit( 'load_mem_disp', $node->type, [ $sb, 4096 + ( $idx * 8 ) ] );
                return ( $res, $node->type );
            }
            if ( $node isa Brocken::AST::VarDecl ) {
                my ( $v_reg, $v_typ ) = $self->lower( $node->value );
                my $sym     = $current_scope->define( $node->name, $node->type );
                my $var_reg = $builder->emit( 'mov', 'i64', [$v_reg] );
                $sym->ssa_reg($var_reg);
                return ( $var_reg, $node->type );
            }
            if ( $node isa Brocken::AST::Assignment ) {
                my ( $v_reg, $v_typ ) = $self->lower( $node->value );
                my $sym = $current_scope->resolve( $node->name ) // die "Undeclared " . $node->name . "\n";
                if ($sym->is_state) {
                    my $sb  = $builder->emit( 'load_iso_disp', 'ptr', [16] );
                    $builder->emit( 'store_mem_disp', 'void', [ $sb, 4096 + ( $sym->state_idx * 8 ), $v_reg ] );
                    return ( $v_reg, $sym->type );
                }
                $builder->emit( 'mov', 'i64', [$v_reg], $sym->ssa_reg );
                return ( $sym->ssa_reg, $sym->type );
            }
            if ( $node isa Brocken::AST::BinOp ) {
                my ( $l_reg, $l_typ ) = $self->lower( $node->left );
                my ( $r_reg, $r_typ ) = $self->lower( $node->right );
                my $op_map = { '+' => 'add', '-' => 'sub', '*' => 'mul', '==' => 'cmp_eq', '!=' => 'cmp_ne', '<' => 'cmp_lt', '>' => 'cmp_gt' };
                my $op     = $op_map->{ $node->op } // die "Unknown op: " . $node->op;
                return ( $builder->emit( $op, 'i64', [ $l_reg, $r_reg ] ), 'Int' );
            }
            if ( $node isa Brocken::AST::Map ) {
                my ( $src_reg, $src_type ) = $self->lower( $node->source );
                my $res_reg = $builder->emit( 'map_op', 'Array', [ $src_reg, $node->expr ] );
                $builder->emit( 'shadow_push', 'void', [$res_reg] );
                return ( $res_reg, 'Array' );
            }
            if ( $node isa Brocken::AST::Call ) {
                if ( $node->name =~ /^(say|print)$/ ) {
                    my ( $r, $t ) = $self->lower( $node->args->[0] );
                    if ( $t eq 'Int' ) {
                        $builder->emit( 'call_func', 'void', [ 'M_print_int', $r ] );
                    }
                    else {
                        $builder->emit( 'builtin_print', 'void', [$r] );
                    }
                    if ( $node->name eq 'say' ) {
                        my $nl = $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string("\n") ] );
                        $builder->emit( 'builtin_print', 'void', [$nl] );
                    }
                    return ( undef, 'void' );
                }
                my @args = map { ( $self->lower($_) )[0] } @{ $node->args };
                return ( $builder->emit( 'call_func', 'i64', [ "M_" . $node->name, @args ] ), 'Int' );
            }
            if ( $node isa Brocken::AST::Return ) {
                my ( $r, $t ) = $self->lower( $node->expr );
                $builder->emit( 'leave_func', 'void', [$r] );
                return ( undef, 'void' );
            }
            if ( $node isa Brocken::AST::If ) {
                my $l_then = $builder->new_label();
                my $l_else = $builder->new_label();
                my $l_end  = $builder->new_label();
                my ( $c_reg, $c_typ ) = $self->lower( $node->condition );
                $builder->emit_cond_br( $c_reg, $l_then, $l_else );
                $builder->emit_label($l_then);
                $self->lower( $node->then_block );
                $builder->emit_jump($l_end);
                $builder->emit_label($l_else);
                $self->lower( $node->else_block ) if $node->else_block;
                $builder->emit_label($l_end);
                return ( undef, 'void' );
            }
            if ( $node isa Brocken::AST::While ) {
                my $l_start = $builder->new_label();
                my $l_body  = $builder->new_label();
                my $l_end   = $builder->new_label();
                $builder->emit_label($l_start);
                my ( $c_reg, $c_typ ) = $self->lower( $node->condition );
                $builder->emit_cond_br( $c_reg, $l_body, $l_end );
                $builder->emit_label($l_body);
                $self->lower( $node->body );
                $builder->emit_jump($l_start);
                $builder->emit_label($l_end);
                return ( undef, 'void' );
            }
            if ( $node isa Brocken::AST::ArrayLiteral ) {
                my $count   = scalar @{ $node->elements };
                my $size    = 24 + ( $count * 8 );
                my $sz_reg  = $builder->emit( 'constant',  'i64', [$size] );
                my $arr_ptr = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', $sz_reg ] );
                $builder->emit( 'shadow_push', 'void', [$arr_ptr] );
                my $c_reg = $builder->emit( 'constant', 'i64', [$count] );
                $builder->emit( 'store_mem_disp', 'void', [ $arr_ptr, 0, $sz_reg ] );
                $builder->emit( 'store_mem_disp', 'void', [ $arr_ptr, 8, $c_reg ] );
                my $idx = 0;

                for my $el ( @{ $node->elements } ) {
                    my ( $r, $t ) = $self->lower($el);
                    $builder->emit( 'store_mem_disp', 'void', [ $arr_ptr, 24 + ( $idx * 8 ), $r ] );
                    $idx++;
                }
                return ( $arr_ptr, 'Array' );
            }
            return ( undef, 'void' );
        }
    }

    class Brocken::Compiler::Optimizer {

        method optimize($builder) {
            my @instructions = $builder->instructions();
            my $changed      = 1;
            while ($changed) {
                $changed = 0;
                my %def;
                my %use_count;
                my %shadow_push_inst;    # Map register to its shadow_push instruction

                # 1. First Pass: Analyze definitions and use counts
                for my $i (@instructions) {
                    $def{ $i->{dest} } = $i if defined $i->{dest};

                    # Track usages in args
                    if ( defined $i->{args} ) {
                        for my $arg ( @{ $i->{args} } ) {
                            $use_count{$arg}++ if defined $arg && !ref($arg) && $arg =~ /^%/;
                        }
                    }

                    # IMPORTANT: Track usages in cond_br (previously missing!)
                    if ( $i->{op} eq 'cond_br' && $i->{reg} ) {
                        $use_count{ $i->{reg} }++;
                    }

                    # Track shadow_push metadata
                    if ( $i->{op} eq 'shadow_push' ) {
                        $shadow_push_inst{ $i->{args}[0] } = $i;
                    }
                }

                # 2. Second Pass: Perform Fusion
                for my $i (@instructions) {
                    if ( $i->{op} eq 'map_op' ) {
                        my $src_reg  = $i->{args}[0];
                        my $def_inst = $def{$src_reg};
                        if ( $def_inst && $def_inst->{op} eq 'map_op' ) {
                            my $count = $use_count{$src_reg} // 0;

                            # FUSION CONDITION:
                            # Register is used only by the next map,
                            # OR it's used by the next map AND a shadow_push (which we can delete).
                            my $has_shadow = exists $shadow_push_inst{$src_reg};
                            if ( $count == 1 || ( $count == 2 && $has_shadow ) ) {

                                # Merge ASTs: replace $_ in current map with inner map's expression
                                my $fused_ast = $self->substitute_ast( $i->{args}[1], '$_', $def_inst->{args}[1] );

                                # Update current instruction to point to the inner map's source
                                $i->{args}[0] = $def_inst->{args}[0];
                                $i->{args}[1] = $fused_ast;

                                # Nop out the instructions that are no longer needed
                                $def_inst->{op} = 'nop';
                                if ($has_shadow) {
                                    $shadow_push_inst{$src_reg}->{op} = 'nop';
                                }
                                $changed = 1;
                            }
                        }
                    }
                }

                # Cleanup nops
                @instructions = grep { $_->{op} ne 'nop' } @instructions;
            }
            $builder->set_instructions(@instructions);
        }

        method substitute_ast( $node, $var_name, $repl_node ) {
            if ( $node isa Brocken::AST::Var ) {
                return $node->name eq $var_name ? $repl_node : $node;
            }
            if ( $node isa Brocken::AST::BinOp ) {
                return Brocken::AST::BinOp->new(
                    op    => $node->op,
                    left  => $self->substitute_ast( $node->left,  $var_name, $repl_node ),
                    right => $self->substitute_ast( $node->right, $var_name, $repl_node )
                );
            }
            if ( $node isa Brocken::AST::Const ) { return $node; }

            # If we encounter something more complex, we stop and die to prevent silent corruption
            die "Optimizer Error: Unhandled AST node " . ref($node) . " in map closure during fusion.";
        }
    }
}
1;
