package Brocken::Compiler {
    use v5.40;
    use utf8;
    use feature 'class';
    no warnings 'portable', 'experimental::class';

    class Brocken::Compiler::Lowering {
        use constant { TAG_INT => 0, TAG_STR => 1, TAG_ARR => 2, TAG_OBJ => 3 };
        field $builder : reader : param = Brocken::IR::Builder->new();
        field $pulse : param;
        field $data_segment : param;
        field $current_scope = Brocken::Scope->new();
        field $state_count   = 0;
        field $routine_depth = 0;

        method inject_runtime() {
            $builder->emit_label('M_gc_alloc');
            $builder->emit( 'enter_func', 'void', [] );
            my $size = $builder->emit( 'get_arg', 'i64', [0] );

            # Isolate Layout: [0] = Current Alloc Pointer, [8] = Limit, [16] = State Block
            my $alloc_ptr = $builder->emit( 'load_iso_disp', 'ptr', [ $pulse->iso_offset('heap_ptr') ] );
            my $limit_ptr = $builder->emit( 'load_iso_disp', 'ptr', [ $pulse->iso_offset('heap_limit') ] );
            my $new_alloc = $builder->emit( 'add',           'ptr', [ $alloc_ptr, $size ] );
            my $l_fast    = $builder->new_label();
            my $l_slow    = $builder->new_label();
            $builder->emit_cond_br( $builder->emit( 'cmp_gt', 'Int', [ $new_alloc, $limit_ptr ] ), $l_slow, $l_fast );
            $builder->emit_label($l_fast);
            $builder->emit( 'store_iso_disp', 'void', [ $pulse->iso_offset('heap_ptr'), $new_alloc ] );
            $builder->emit( 'leave_func',     'void', [$alloc_ptr] );
            $builder->emit_label($l_slow);
            my $new_region = $builder->emit( 'sys_alloc', 'ptr', [65536] );
            my $new_limit  = $builder->emit( 'add',       'ptr', [ $new_region, 65536 ] );
            my $res_alloc  = $builder->emit( 'add',       'ptr', [ $new_region, $size ] );
            $builder->emit( 'store_iso_disp', 'void', [ $pulse->iso_offset('heap_ptr'), $res_alloc ] );
            $builder->emit( 'store_iso_disp', 'void', [ $pulse->iso_offset('heap_limit'), $new_limit ] );
            $builder->emit( 'leave_func',     'void', [$new_region] );
            #
            $builder->emit_label('M_print_int');
            $builder->emit( 'enter_func', 'void', [] );

            # Handle zero case
            my $n       = $builder->emit( 'get_arg', 'i64', [0] );
            my $l_z     = $builder->new_label();
            my $l_not_z = $builder->new_label();
            $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $n, 0 ] ), $l_z, $l_not_z );
            $builder->emit_label($l_z);
            $builder->emit( 'builtin_print_char', 'void', [48] );
            $builder->emit( 'leave_func',         'void', [0] );
            $builder->emit_label($l_not_z);
            my $count  = $builder->emit( 'constant', 'i64', [0] );
            my $l_loop = $builder->new_label();
            my $l_out  = $builder->new_label();
            $builder->emit_label($l_loop);
            my $digit = $builder->emit( 'mod', 'i64', [ $n, 10 ] );
            $builder->emit( 'push', 'void', [ $builder->emit( 'add', 'i64', [ $digit, 48 ] ) ] );
            $count = $builder->emit( 'add', 'i64', [ $count, 1 ], $count );
            $builder->emit( 'div', 'i64', [ $n, 10 ], $n );
            $builder->emit_cond_br( $builder->emit( 'cmp_gt', 'Int', [ $n, 0 ] ), $l_loop, $l_out );
            $builder->emit_label($l_out);
            my $l_p_top = $builder->new_label();
            my $l_p_end = $builder->new_label();
            $builder->emit_label($l_p_top);
            $builder->emit( 'builtin_print_char', 'void', [ $builder->emit( 'pop', 'i64', [] ) ] );
            $count = $builder->emit( 'sub', 'i64', [ $count, 1 ], $count );
            $builder->emit_cond_br( $builder->emit( 'cmp_gt', 'Int', [ $count, 0 ] ), $l_p_top, $l_p_end );
            $builder->emit_label($l_p_end);
            $builder->emit( 'leave_func', 'void', [0] );

            # M_fiber_switch: The core context switcher
            # Logic: Save Current, Swap Stacks, Load Target, Return to Target's RIP
            $builder->emit_label('M_fiber_switch');
            $builder->emit( 'enter_func', 'void', [] );    # Placeholder to save caller-saved

            # Arguments: Arg0 = Target FCB, Arg1 = Value to pass
            my $target_fcb  = $builder->emit( 'get_arg', 'ptr', [0] );
            my $val_to_pass = $builder->emit( 'get_arg', 'ptr', [1] );
            $builder->emit( 'fiber_transfer', 'Any', [ $target_fcb, $val_to_pass ] );

            # The 'fiber_transfer' op in Codegen will now handle the stack swap and RET
            $builder->emit( 'leave_func', 'void', [0] );

            # M_fiber_new: Allocate FCB, Shadow Stack, and Machine Stack (With Guard Page)
            $builder->emit_label('M_fiber_new');
            $builder->emit( 'enter_func', 'void', [] );
            my $func_ptr = $builder->emit( 'get_arg',           'i64', [0] );
            my $fcb      = $builder->emit( 'call_func',         'ptr', [ 'M_gc_alloc', 64 ] );
            my $shadow   = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', 4096 ] );
            my $mstack   = $builder->emit( 'sys_alloc', 'ptr', [1048576] );
            $builder->emit( 'store_mem_disp', 'void', [ $fcb, $pulse->fcb_offset('stack_base'),  $mstack ] );
            $builder->emit( 'store_mem_disp', 'void', [ $fcb, $pulse->fcb_offset('shadow_base'), $shadow ] );
            $builder->emit( 'store_mem_disp', 'void', [ $fcb, $pulse->fcb_offset('shadow_ptr'),  $shadow ] );
            my $top = $builder->emit( 'add', 'ptr', [ $mstack, 1048576 ] );
            $top = $builder->emit( 'sub', 'ptr', [ $top, 8 ] );
            $builder->emit( 'store_mem_disp', 'void', [ $top, 0, $func_ptr ] );    # Fiber Entry RIP

            # Reserve 64 bytes for 8 callee-saved regs (rbp, rsi, rdi, rbx, r12, r13, r14, r15)
            $top = $builder->emit( 'sub', 'ptr', [ $top, 64 ] );

            # Zero-initialize the slots
            for ( my $off = 0; $off < 64; $off += 8 ) {
                $builder->emit( 'store_mem_disp', 'void', [ $top, $off, 0 ] );
            }

            # Initialize r14 (Isolate Context) slot at offset 48 from $top
            # Order: rbp(0), rsi(8), rdi(16), rbx(24), r12(32), r13(40), r14(48), r15(56)
            my $iso_val = $builder->emit( 'get_isolate_ctx', 'ptr', [] );
            $builder->emit( 'store_mem_disp', 'void', [ $top, 48, $iso_val ] );

            $builder->emit( 'store_mem_disp', 'void', [ $fcb, $pulse->fcb_offset('sp'), $top ] );
            $builder->emit( 'leave_func', 'void', [$fcb] );
        }

        method lower_program($nodes) {
            $builder->emit_jump('L_MAIN_START');
            $self->inject_runtime();
            my @methods = grep { $_ isa Brocken::AST::Method } @$nodes;
            my @stmts   = grep { !( $_ isa Brocken::AST::Method ) } @$nodes;
            for my $m (@methods) {
                $builder->emit_label( "M_" . $m->name );
                $builder->emit( 'enter_func', 'void', [] );
                $current_scope = Brocken::Scope->new( parent => $current_scope );
                $routine_depth++;
                my $arg_idx = 0;
                for my $p ( @{ $m->params } ) {
                    my $reg = $builder->emit( 'get_arg', 'i64', [ $arg_idx++ ] );
                    $current_scope->define( $p->{name}, $p->{type} )->ssa_reg($reg);
                }
                $self->lower_block( $m->body->statements );
                $routine_depth--;
                $current_scope = $current_scope->parent;
            }
            $builder->emit_label('L_MAIN_START');
            $builder->emit( 'enter_func',               'void', [] );
            $builder->emit( 'setup_page_fault_handler', 'void', [] );
            my $iso_reg = $builder->emit( 'sys_alloc', 'ptr', [1024] );
            $builder->emit( 'set_isolate_ctx', 'void', [$iso_reg] );
            my $c64k        = $builder->emit( 'constant',  'i64', [65536] );
            my $init_region = $builder->emit( 'sys_alloc', 'ptr', [$c64k] );
            $builder->emit( 'store_iso_disp', 'void', [ $pulse->iso_offset('heap_ptr'),  $init_region ] );
            $builder->emit( 'store_iso_disp', 'void', [ $pulse->iso_offset('heap_limit'),  $builder->emit( 'add',       'ptr', [ $init_region, $c64k ] ) ] );
            $builder->emit( 'store_iso_disp', 'void', [ $pulse->iso_offset('state_ptr'), $builder->emit( 'sys_alloc', 'ptr', [$c64k] ) ] );

            # Create Main FCB and Link Shadow Stack
            my $main_fcb  = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', 64 ] );
            my $main_shad = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', 1048576 ] );
            $builder->emit( 'store_mem_disp', 'void', [ $main_fcb, $pulse->fcb_offset('shadow_base'), $main_shad ] );
            $builder->emit( 'store_mem_disp', 'void', [ $main_fcb, $pulse->fcb_offset('shadow_ptr'), $main_shad ] );
            $builder->emit( 'store_iso_disp', 'void', [ $pulse->iso_offset('current_fcb'), $main_fcb ] );    # Isolate current FCB
            $self->lower_block( \@stmts );
            $builder->emit( 'exit_program',         'void', [0] );
            $builder->emit( 'emit_native_handlers', 'void', [] );             # Emits OS-level VEH/Signal code
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
                if ( $sym->is_state ) {
                    my $sb  = $builder->emit( 'load_iso_disp', 'ptr',      [ $pulse->iso_offset('state_ptr') ] );
                    my $res = $builder->emit( 'load_mem_disp', $sym->type, [ $sb, 4096 + ( $sym->state_idx * 8 ) ] );
                    return ( $res, $sym->type );
                }
                return ( $sym->ssa_reg, $sym->type );
            }
            if ( $node isa Brocken::AST::StateDecl ) {
                my $idx    = $state_count++;
                my $sym    = $current_scope->define( $node->name, $node->type, 1, $idx );
                my $l_init = $builder->new_label();
                my $l_done = $builder->new_label();
                my $sb     = $builder->emit( 'load_iso_disp', 'ptr', [ $pulse->iso_offset('state_ptr') ] );
                $builder->emit_cond_br( $builder->emit( 'load_mem_byte', 'Int', [ $sb, $idx ] ), $l_done, $l_init );
                $builder->emit_label($l_init);
                my ( $v_reg, $v_typ ) = $self->lower( $node->value );
                $builder->emit( 'store_mem_byte', 'void', [ $sb, $idx, 1 ] );
                $builder->emit( 'store_mem_disp', 'void', [ $sb, 4096 + ( $idx * 8 ), $v_reg ] );
                $builder->emit_jump($l_done);
                $builder->emit_label($l_done);
                my $res = $builder->emit( 'load_mem_disp', $node->type, [ $sb, 4096 + ( $idx * 8 ) ] );
                $sym->ssa_reg($res);
                return ( $res, $node->type );
            }
            if ( $node isa Brocken::AST::VarDecl ) {
                my ( $v_reg, $v_typ ) = $self->lower( $node->value );
                my $decl_type = $node->type eq 'Any' ? $v_typ : $node->type;
                my $sym     = $current_scope->define( $node->name, $decl_type );
                my $var_reg = $builder->emit( 'mov', 'i64', [$v_reg] );
                $sym->ssa_reg($var_reg);
                return ( $var_reg, $decl_type );
            }
            if ( $node isa Brocken::AST::Assignment ) {
                my ( $v_reg, $v_typ ) = $self->lower( $node->value );
                my $sym = $current_scope->resolve( $node->name ) // die "Undeclared " . $node->name . "\n";
                if ( $sym->is_state ) {
                    my $sb = $builder->emit( 'load_iso_disp', 'ptr', [ $pulse->iso_offset('state_ptr') ] );
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
                return ( $builder->emit( $op_map->{ $node->op }, 'i64', [ $l_reg, $r_reg ] ), 'Int' );
            }
            if ( $node isa Brocken::AST::Map ) {
                my ( $src_reg, $src_type ) = $self->lower( $node->source );
                my $res_reg = $builder->emit( 'map_op', 'Array', [ $src_reg, $node->expr ] );
                $builder->emit( 'shadow_push', 'void', [$res_reg] );
                return ( $res_reg, 'Array' );
            }
            if ( $node isa Brocken::AST::FiberBlock ) {
                my $fib_label = $builder->new_label();

                # Use array operations safely since instructions is a field
                my @current_instructions = $builder->instructions;
                $builder->set_instructions();    # Clear for the fiber block
                $builder->emit_label($fib_label);
                $current_scope = Brocken::Scope->new( parent => $current_scope );
                $routine_depth++;
                my ( $res, $type ) = $self->lower_block( $node->body->statements );
                $routine_depth--;
                $current_scope = $current_scope->parent;

                # Fiber exit: Yield back to caller
                my $curr   = $builder->emit( 'load_iso_disp', 'ptr', [ $pulse->iso_offset('current_fcb') ] );
                my $caller = $builder->emit( 'load_mem_disp', 'ptr', [ $curr, $pulse->fcb_offset('caller') ] );
                $builder->emit( 'fiber_transfer', 'Any', [ $caller, $res // 0 ] );
                $builder->emit( 'leave_func', 'void', [0] );

                # Save the new fiber instructions and restore the builder
                my @new_inst = $builder->instructions;
                push @current_instructions, @new_inst;
                $builder->set_instructions(@current_instructions);
                my $fcb = $builder->emit( 'call_func', 'ptr', [ 'M_fiber_new', $fib_label ] );
                return ( $fcb, 'Fiber' );
            }
            if ( $node isa Brocken::AST::Yield ) {
                my ($v_reg) = $self->lower( $node->expr );
                my $curr    = $builder->emit( 'load_iso_disp', 'ptr', [ $pulse->iso_offset('current_fcb') ] );
                my $caller  = $builder->emit( 'load_mem_disp', 'ptr', [ $curr, $pulse->fcb_offset('caller') ] );
                return ( $builder->emit( 'call_func', 'Int', [ 'M_fiber_switch', $caller, $v_reg ] ), 'Int' );
            }
            if ( $node isa Brocken::AST::Call ) {
                if ( $node->name eq 'transfer' ) {
                    my ($t_reg) = $self->lower( $node->args->[0] );
                    my ($v_reg) = $self->lower( $node->args->[1] );
                    return ( $builder->emit( 'call_func', 'Int', [ 'M_fiber_switch', $t_reg, $v_reg ] ), 'Int' );
                }
                if ( $node->name =~ /^(say|print)$/ ) {
                    my ( $r, $t ) = $self->lower( $node->args->[0] );
                    $builder->emit( ( $t eq 'Int' ? 'call_func' : 'builtin_print' ), 'void', ( $t eq 'Int' ? [ 'M_print_int', $r ] : [$r] ) );
                    if ( $node->name eq 'say' ) {
                        $builder->emit( 'builtin_print', 'void', [ $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string("\n") ] ) ] );
                    }
                    return ( undef, 'void' );
                }
                my @args = map { ( $self->lower($_) )[0] } @{ $node->args };
                return ( $builder->emit( 'call_func', 'i64', [ "M_" . $node->name, @args ] ), 'Int' );
            }
            if ( $node isa Brocken::AST::Return ) {
                die "Semantic Error: return outside of subroutine or fiber\n" if $routine_depth == 0;
                my ( $r, $t ) = $self->lower( $node->expr );
                $builder->emit( 'leave_func', 'void', [$r] );
                return ( undef, 'void' );
            }
            if ( $node isa Brocken::AST::Exit ) {
                my ( $r, $t ) = $self->lower( $node->expr );
                $builder->emit( 'exit_program', 'void', [$r] );
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
            return unless @instructions;
            my $changed = 1;
            while ($changed) {
                $changed = 0;
                my %def;
                my %use_count;
                my %shadow_map;
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
            die "Optimizer Error: Unhandled AST node " . ref($node) . " in map closure during fusion.";
        }
    }
}
1;
