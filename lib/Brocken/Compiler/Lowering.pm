package Brocken::Compiler::Lowering {
    use v5.40;
    use utf8;
    use feature 'class';
    no warnings 'portable', 'experimental::class';
    use Brocken::IR;
    use Brocken::AST;

    class Brocken::Compiler::Lowering {
        field $builder      : reader : param = Brocken::IR::Builder->new();
        field $driver       : param;
        field $data_segment : param;
        field $current_scope = Brocken::Scope->new();
        field $state_count   = 0;
        field $routine_depth = 0;
        field @routine_types = ('main');
        field %class_info;
        field %global_methods;
        field $global_method_count = 0;
        field $class_id_counter    = 0;
        field $anon_counter        = 0;
        field @fragments;
        field @defer_stack; # Stack of [ \@instructions ]
        my $BLOCK_SIZE = 32768;
        my $LINE_SIZE  = 128;

        # Helpers
        method _emit_bool_test($reg) {

            # In Brocken Smi: False is 1, True is 3. CPU needs 0/1.
            return $builder->emit( 'cmp_ne', 'Int', [ $reg, $builder->emit( 'constant', 'i64', [1] ) ] );
        }

       method _emit_all_defers() {
           # LIFO: Reverse the stack of currently deferred actions
           for my $fragment (reverse @defer_stack) {
               $builder->push_instruction($_) for @$fragment;
           }
       }

        method _lower_logical($node) {
            my $is_and   = $node->op eq '&&';
            my $res_slot = $driver->alloc_local_slot();
            my $l_short  = $builder->new_label();
            my $l_end    = $builder->new_label();
            my ( $l_reg, $l_typ ) = $self->lower( $node->left );
            if ($is_and) {
                $builder->emit_cond_br( $l_reg, $builder->new_label(), $l_short );
            }
            else {
                $builder->emit_cond_br( $l_reg, $l_short, $builder->new_label() );
            }
            $builder->emit_label( $builder->last_instruction->{ ( $is_and ? 'true_l' : 'false_l' ) } );
            my ( $r_reg, $r_typ ) = $self->lower( $node->right );
            my $bool_r = $builder->emit( 'cmp_ne', 'Int', [ $r_reg, 0 ] );
            $builder->emit( 'local_store', 'void', [ $res_slot, $bool_r ] );
            $builder->emit_jump($l_end);
            $builder->emit_label($l_short);
            my $short_val = $builder->emit( 'constant', 'i64', [ $is_and ? 0 : 1 ] );
            $builder->emit( 'local_store', 'void', [ $res_slot, $short_val ] );
            $builder->emit_label($l_end);
            return ( $builder->emit( 'local_load', 'Int', [$res_slot] ), 'Int' );
        }

        method capture_fragment( $label, $logic_sub ) {
            my @saved = $builder->instructions;
            $builder->set_instructions();
            $logic_sub->();
            my @captured = $builder->instructions;
            push @fragments, \@captured;
            $builder->set_instructions(@saved);
        }

        # --- Core Dispatcher ---
        method lower($node) {
            return ( undef, 'void' ) unless defined $node;
            my $node_type = ref($node);
            $node_type =~ s/.*:://;
            my $method = "lower_$node_type";
            if ( $self->can($method) ) { return $self->$method($node); }
            die "Lowering Error: No handler implemented for AST node type '$node_type' (" . ref($node) . ")";
        }

        method lower_block($statements) {
            my ( $reg, $type );
            for my $stmt (@$statements) { ( $reg, $type ) = $self->lower($stmt); }
            return ( $reg, $type );
        }

        method lower_program($nodes) {
            $builder->emit_jump('L_MAIN_START');
            $self->inject_runtime();
            $self->register_classes($nodes);
            my @main_stmts;
            for my $node (@$nodes) {
                if    ( $node isa Brocken::AST::OOP::Method )    { $self->lower($node); }
                elsif ( $node isa Brocken::AST::OOP::ClassDecl ) { $self->lower($node); }
                else                                             { push @main_stmts, $node; }
            }
            $driver->reset_locals();
            $builder->emit_label('L_MAIN_START');
            $builder->emit( 'enter_func',                    'void', [] );
            $builder->emit( 'intrinsic_setup_fault_handler', 'void', [] );
            $builder->emit( 'intrinsic_setup_env',           'void', [] );
            my $iso_reg = $builder->emit( 'intrinsic_alloc', 'ptr', [1024] );

            $builder->emit( 'set_isolate_ctx', 'void', [$iso_reg] );

            # Pointer initialization (Use raw 0 for linked lists)
            $builder->emit( 'store_mem_disp', 'void', [ $iso_reg, $driver->iso_offset('fiber_head'), $builder->emit( 'constant', 'i64', [0] ) ] );
            $builder->emit( 'store_mem_disp', 'void', [ $iso_reg, 80, $builder->emit('constant', 'i64', [1]) ] ); # Init GC Cycle

            my $c1m       = $builder->emit( 'constant',        'i64', [32768] );
            my $init_heap = $builder->emit( 'intrinsic_alloc', 'ptr', [$c1m] );
            $builder->emit( 'store_iso_disp', 'void', [ 40, $init_heap ] );
            $builder->emit( 'store_mem_disp', 'void', [ $init_heap, 256, $builder->emit('constant', 'i64', [0]) ] );
            my $first_line = $builder->emit( 'add', 'ptr', [ $init_heap, 264 ] );
            $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('heap_ptr'),   $first_line ] );
            $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('heap_limit'), $builder->emit( 'add', 'ptr', [ $init_heap, $c1m ] ) ] );

            my $state_mem = $builder->emit( 'intrinsic_alloc', 'ptr', [1048576] );
            $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('state_ptr'), $state_mem ] );

            for my $cname ( sort keys %class_info ) {
                my $c           = $class_info{$cname};
                my $ptr_count   = scalar @{ $c->{ptr_offsets} };
                my $meta_size   = ( 1 + $ptr_count ) * 8;
                my $vt_raw      = $builder->emit( 'intrinsic_alloc', 'ptr', [ $meta_size + ( $global_method_count * 8 ) ] );
                my $method_base = $builder->emit( 'add', 'ptr', [ $vt_raw, $meta_size ] );
                $builder->emit( 'store_mem_disp', 'void', [ $method_base, -8, $builder->emit( 'constant', 'i64', [$ptr_count] ) ] );
                for ( my $i = 0; $i < $ptr_count; $i++ ) {
                    $builder->emit( 'store_mem_disp', 'void',
                        [ $method_base, -16 - ( $i * 8 ), $builder->emit( 'constant', 'i64', [ $c->{ptr_offsets}[$i] ] ) ] );
                }
                for my $mname ( @{ $c->{method_names} } ) {
                    my $gidx  = $global_methods{$mname};
                    my $f_ptr = $builder->emit( 'load_func_addr', 'ptr', ["M_${cname}::${mname}"] );
                    $builder->emit( 'store_mem_disp', 'void', [ $method_base, $gidx * 8, $f_ptr ] );
                }
                $builder->emit( 'store_mem_disp', 'void', [ $state_mem, $c->{id} * 8, $method_base ] );
            }

            # Initialize "Main" Fiber
            my $leaf_64   = $builder->emit( 'constant',  'i64', [ 64 | hex("2000000000000000") ] );
            my $leaf_64k  = $builder->emit( 'constant',  'i64', [ 65536 | hex("2000000000000000") ] );
            my $main_fcb  = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', $leaf_64 ] );
            my $main_shad = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', $leaf_64k ] );
            $builder->emit( 'store_mem_disp', 'void', [ $main_fcb, $driver->fcb_offset('shadow_base'), $main_shad ] );
            $builder->emit( 'store_mem_disp', 'void', [ $main_fcb, $driver->fcb_offset('shadow_ptr'),  $main_shad ] );
            $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('current_fcb'), $main_fcb ] );

            $builder->emit( 'store_mem_disp', 'void', [ $main_fcb, $driver->fcb_offset('caller'), $builder->emit( 'constant', 'i64', [0] ) ] );
            $builder->emit( 'store_mem_disp', 'void', [ $main_fcb, $driver->fcb_offset('next'),   $builder->emit( 'constant', 'i64', [0] ) ] );
            $builder->emit( 'store_mem_disp', 'void',
                [ $builder->emit( 'get_isolate_ctx', 'ptr', [] ), $driver->iso_offset('fiber_head'), $main_fcb ] );
            $self->lower_block( \@main_stmts );
            $builder->emit( 'intrinsic_exit', 'void', [0] );
            while (@fragments) {
                my $frag = shift @fragments;
                $builder->push_instruction($_) for @$frag;
            }
            $builder->emit( 'intrinsic_emit_runtime', 'void', [] );
        }

        method register_classes($nodes) {
            for my $node (@$nodes) {
                if ( $node isa Brocken::AST::OOP::ClassDecl ) {
                    my $id = $class_id_counter++;
                    my @method_names;
                    my @ptr_offsets;
                    my $curr_off = 16;
                    for my $m ( @{ $node->methods } ) { push @method_names, $m->name; $global_methods{ $m->name } //= $global_method_count++; }
                    for my $f ( @{ $node->fields } ) {
                        push @ptr_offsets, $curr_off if $f->type =~ /^(Any|String|Array|Class)$/;
                        $curr_off += 8;
                    }
                    $class_info{ $node->name } = { id => $id, method_names => \@method_names, ptr_offsets => \@ptr_offsets, fields => $node->fields };
                }
            }
        }

        method inject_runtime() {

            # --- [1] GC Marking ---
            {
                $driver->reset_locals();
                $builder->emit_label('M_gc_mark_obj');
                $builder->emit( 'enter_func', 'void', [] );
                my $obj   = $builder->emit( 'get_arg', 'ptr', [0] );
                my $l_end = $builder->new_label();
                $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $obj, 0 ] ), $l_end, $builder->new_label() );
                $builder->emit_label( $builder->last_instruction->{false_l} );

                # Smi Check
                my $is_smi = $builder->emit( 'and', 'i64', [ $obj, $builder->emit( 'constant', 'i64', [1] ) ] );
                $builder->emit_cond_br( $builder->emit( 'cmp_ne', 'Int', [ $is_smi, 0 ] ), $l_end, $builder->new_label() );
                $builder->emit_label( $builder->last_instruction->{false_l} );

                # Retrieve GC Cycle from bits 32-55 in header
                my $header    = $builder->emit( 'load_mem_disp', 'i64', [ $obj, -8 ] );
                my $cycle     = $builder->emit( 'load_iso_disp', 'i64', [80] );
                my $obj_cycle = $builder->emit('and', 'i64', [$builder->emit('shr', 'i64', [$header, 32]), $builder->emit('constant', 'i64', [0xFFFFFF])]);
                $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $obj_cycle, $cycle ] ), $l_end, $builder->new_label() );
                $builder->emit_label( $builder->last_instruction->{false_l} );

                # Clear old cycle info, attach new rolling cycle marker
                my $mask = $builder->emit('constant', 'i64', [hex("FF000000FFFFFFFF")]);
                my $cleared = $builder->emit('and', 'i64', [$header, $mask]);
                my $new_header = $builder->emit('or', 'i64', [$cleared, $builder->emit('shl', 'i64', [$cycle, 32])]);
                $builder->emit('store_mem_disp', 'void', [$obj, -8, $new_header]);
                $header = $new_header;

                my $heap_base     = $builder->emit( 'load_iso_disp', 'ptr', [40] );
                my $is_static     = $builder->emit( 'cmp_lt',        'Int', [ $obj, $heap_base ] );
                my $l_immix       = $builder->new_label();
                my $l_trace_check = $builder->new_label();
                $builder->emit_cond_br( $is_static, $l_trace_check, $l_immix );
                $builder->emit_label($l_immix);
                my $block_mask = $builder->emit( 'constant', 'i64', [-32768] );
                my $block      = $builder->emit( 'and',      'i64', [ $obj, $block_mask ] );
                my $line_idx   = $builder->emit( 'div',      'i64', [ $builder->emit( 'sub', 'i64', [ $obj, $block ] ), $LINE_SIZE ] );
                $builder->emit( 'store_mem_byte', 'void', [ $block, $line_idx, 1 ] );
                $builder->emit_label($l_trace_check);

                my $leaf_mask = $builder->emit( 'constant', 'i64', [ hex("2000000000000000") ] );
                my $is_leaf   = $builder->emit( 'and',      'i64', [ $header, $leaf_mask ] );
                $builder->emit_cond_br( $builder->emit( 'cmp_ne', 'Int', [ $is_leaf, 0 ] ), $l_end, $builder->new_label() );
                $builder->emit_label( $builder->last_instruction->{false_l} );
                my $arr_mask = $builder->emit( 'constant', 'i64', [ hex("4000000000000000") ] );
                my $is_arr   = $builder->emit( 'and',      'i64', [ $header, $arr_mask ] );
                my $l_obj    = $builder->new_label();
                $builder->emit_cond_br( $is_arr, $builder->new_label(), $l_obj );

                # Array Trace
                $builder->emit_label( $builder->last_instruction->{true_l} );
                my $raw_count  = $builder->emit( 'load_mem_disp', 'i64', [ $obj, 0 ] );
                my $a_count    = $builder->emit( 'div', 'i64', [ $builder->emit( 'sub', 'i64', [ $raw_count, 1 ] ), 2 ] );
                my $a_idx_slot = $driver->alloc_local_slot();
                $builder->emit( 'local_store', 'void', [ $a_idx_slot, $builder->emit( 'constant', 'i64', [0] ) ] );
                my $l_al = $builder->new_label();
                my $l_ad = $builder->new_label();
                $builder->emit_label($l_al);
                my $ca = $builder->emit( 'local_load', 'i64', [$a_idx_slot] );
                $builder->emit_cond_br( $builder->emit( 'cmp_lt', 'Int', [ $ca, $a_count ] ), $builder->new_label(), $l_ad );
                $builder->emit_label( $builder->last_instruction->{true_l} );
                my $a_el = $builder->emit(
                    'load_mem_disp',
                    'ptr',
                    [   $builder->emit( 'add', 'ptr', [ $obj, $builder->emit( 'add', 'i64', [ 8, $builder->emit( 'mul', 'i64', [ $ca, 8 ] ) ] ) ] ),
                        0
                    ]
                );
                $builder->emit( 'call_func', 'void', [ 'M_gc_mark_obj', $a_el ] );
                $builder->emit( 'local_store', 'void', [ $a_idx_slot, $builder->emit( 'add', 'i64', [ $ca, 1 ] ) ] );
                $builder->emit_jump($l_al);
                $builder->emit_label($l_ad);
                $builder->emit_jump($l_end);

                # Object Trace
                $builder->emit_label($l_obj);
                my $vt   = $builder->emit( 'load_mem_disp', 'ptr', [ $obj, 0 ] );
                my $l_nv = $builder->new_label();
                $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $vt, 0 ] ), $l_nv, $builder->new_label() );
                $builder->emit_label( $builder->last_instruction->{false_l} );
                my $p_count    = $builder->emit( 'load_mem_disp', 'i64', [ $vt, -8 ] );
                my $p_idx_slot = $driver->alloc_local_slot();
                $builder->emit( 'local_store', 'void', [ $p_idx_slot, $builder->emit( 'constant', 'i64', [0] ) ] );
                my $l_ol = $builder->new_label();
                $builder->emit_label($l_ol);
                my $cp = $builder->emit( 'local_load', 'i64', [$p_idx_slot] );
                $builder->emit_cond_br( $builder->emit( 'cmp_lt', 'Int', [ $cp, $p_count ] ), $builder->new_label(), $l_nv );
                $builder->emit_label( $builder->last_instruction->{true_l} );
                my $meta_addr
                    = $builder->emit( 'sub', 'ptr', [ $vt, $builder->emit( 'add', 'i64', [ 16, $builder->emit( 'mul', 'i64', [ $cp, 8 ] ) ] ) ] );
                my $fo = $builder->emit( 'load_mem_disp', 'i64', [ $meta_addr, 0 ] );
                $builder->emit( 'call_func', 'void',
                    [ 'M_gc_mark_obj', $builder->emit( 'load_mem_disp', 'ptr', [ $builder->emit( 'add', 'ptr', [ $obj, $fo ] ), 0 ] ) ] );
                $builder->emit( 'local_store', 'void', [ $p_idx_slot, $builder->emit( 'add', 'i64', [ $cp, 1 ] ) ] );
                $builder->emit_jump($l_ol);
                $builder->emit_label($l_nv);
                $builder->emit_label($l_end);
                $builder->emit( 'leave_func', 'void', [0] );
            }

            # --- [2] GC Sweep ---
            {
                $builder->emit_label('M_gc_sweep');
                $builder->emit( 'enter_func', 'void', [] );
                my $bh_slot = $driver->alloc_local_slot();
                $builder->emit('local_store', 'void', [$bh_slot, $builder->emit('load_iso_disp', 'ptr', [40])]);
                my $l_loop = $builder->new_label();
                my $l_end = $builder->new_label();
                $builder->emit_label($l_loop);
                my $curr_bh = $builder->emit('local_load', 'ptr', [$bh_slot]);
                $builder->emit_cond_br($builder->emit('cmp_eq', 'Int', [$curr_bh, 0]), $l_end, $builder->new_label());
                $builder->emit_label($builder->last_instruction->{false_l});

                my $mark_sum = $builder->emit('constant', 'i64', [0]);
                for (my $off = 0; $off < 256; $off += 8) {
                    my $val = $builder->emit('load_mem_disp', 'i64', [$curr_bh, $off]);
                    $mark_sum = $builder->emit('or', 'i64', [$mark_sum, $val]);
                }
                my $l_not_empty = $builder->new_label();
                $builder->emit_cond_br($builder->emit('cmp_eq', 'Int', [$mark_sum, 0]), $builder->new_label(), $l_not_empty);
                $builder->emit_label($builder->last_instruction->{true_l});
                $builder->emit('store_iso_disp', 'void', [$driver->iso_offset('heap_ptr'), $builder->emit('add', 'ptr', [$curr_bh, 264])]);
                $builder->emit('store_iso_disp', 'void', [$driver->iso_offset('heap_limit'), $builder->emit('add', 'ptr', [$curr_bh, 32768])]);
                $builder->emit('leave_func', 'void', [0]);

                $builder->emit_label($l_not_empty);
                $builder->emit('local_store', 'void', [$bh_slot, $builder->emit('load_mem_disp', 'ptr', [$curr_bh, 256])]);
                $builder->emit_jump($l_loop);

                $builder->emit_label($l_end);
                $builder->emit( 'leave_func', 'void', [0] );
            }

            # --- [3] GC Collect (Root Walking) ---
            {
                $builder->emit_label('M_gc_collect');
                $builder->emit( 'enter_func', 'void', [] );

                # Increment rolling GC cycle
                my $cycle = $builder->emit('load_iso_disp', 'i64', [80]);
                $cycle = $builder->emit('add', 'i64', [$cycle, 1]);
                $builder->emit('store_iso_disp', 'void', [80, $cycle]);

                # Clear line marks via block traversal
                my $bh_slot = $driver->alloc_local_slot();
                $builder->emit('local_store', 'void', [$bh_slot, $builder->emit('load_iso_disp', 'ptr', [40])]);
                my $l_bc1 = $builder->new_label();
                my $l_bc2 = $builder->new_label();
                $builder->emit_label($l_bc1);
                my $curr_bh = $builder->emit('local_load', 'ptr', [$bh_slot]);
                $builder->emit_cond_br($builder->emit('cmp_eq', 'Int', [$curr_bh, 0]), $l_bc2, $builder->new_label());
                $builder->emit_label($builder->last_instruction->{false_l});
                for (my $off = 0; $off < 256; $off += 8) {
                    $builder->emit('store_mem_disp', 'void', [$curr_bh, $off, $builder->emit('constant', 'i64', [0])]);
                }
                $builder->emit('local_store', 'void', [$bh_slot, $builder->emit('load_mem_disp', 'ptr', [$curr_bh, 256])]);
                $builder->emit_jump($l_bc1);
                $builder->emit_label($l_bc2);

                my $fib_slot = $driver->alloc_local_slot();
                $builder->emit( 'local_store', 'void', [ $fib_slot, $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('fiber_head') ] ) ] );
                my $l_fl = $builder->new_label();
                my $l_fd = $builder->new_label();
                $builder->emit_label($l_fl);
                my $fib = $builder->emit('local_load', 'ptr', [$fib_slot]);
                $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $fib, 0 ] ), $l_fd, $builder->new_label() );
                $builder->emit_label( $builder->last_instruction->{false_l} );
                my $bs_slot = $driver->alloc_local_slot();
                my $ps_slot = $driver->alloc_local_slot();
                $builder->emit( 'local_store', 'void',
                    [ $bs_slot, $builder->emit( 'load_mem_disp', 'ptr', [ $fib, $driver->fcb_offset('shadow_base') ] ) ] );
                $builder->emit( 'local_store', 'void',
                    [ $ps_slot, $builder->emit( 'load_mem_disp', 'ptr', [ $fib, $driver->fcb_offset('shadow_ptr') ] ) ] );
                my $l_sl = $builder->new_label();
                my $l_sd = $builder->new_label();
                $builder->emit_label($l_sl);
                my $cbs = $builder->emit( 'local_load', 'ptr', [$bs_slot] );
                $builder->emit_cond_br( $builder->emit( 'cmp_ge', 'Int', [ $cbs, $builder->emit( 'local_load', 'ptr', [$ps_slot] ) ] ),
                    $l_sd, $builder->new_label() );
                $builder->emit_label( $builder->last_instruction->{false_l} );
                $builder->emit( 'call_func', 'void', [ 'M_gc_mark_obj', $builder->emit( 'load_mem_disp', 'ptr', [ $cbs, 0 ] ) ] );
                $builder->emit( 'local_store', 'void', [ $bs_slot, $builder->emit( 'add', 'ptr', [ $cbs, 8 ] ) ] );
                $builder->emit_jump($l_sl);
                $builder->emit_label($l_sd);
                $builder->emit( 'local_store', 'void', [ $fib_slot, $builder->emit( 'load_mem_disp', 'ptr', [ $fib, $driver->fcb_offset('next') ] ) ] );
                $builder->emit_jump($l_fl);
                $builder->emit_label($l_fd);
                $builder->emit( 'call_func',  'void', ['M_gc_sweep'] );
                $builder->emit( 'leave_func', 'void', [0] );
            }

            # --- [4] Immix Allocator ---
            {
                $driver->reset_locals();
                $builder->emit_label('M_gc_alloc');
                $builder->emit( 'enter_func', 'void', [] );
                my $psz = $builder->emit( 'get_arg',       'i64', [0] );
                my $rsz = $builder->emit( 'and',           'i64', [ $psz, $builder->emit( 'constant', 'i64', [ hex("1FFFFFFFFFFFFFFF") ] ) ] );
                my $sz  = $builder->emit( 'add',           'i64', [ $rsz, 8 ] );
                my $ap  = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('heap_ptr') ] );
                my $lp  = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('heap_limit') ] );
                my $l_f = $builder->new_label();
                my $l_s = $builder->new_label();
                $builder->emit_cond_br( $builder->emit( 'cmp_lt', 'Int', [ $builder->emit( 'add', 'ptr', [ $ap, $sz ] ), $lp ] ), $l_f, $l_s );
                $builder->emit_label($l_f);
                $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('heap_ptr'), $builder->emit( 'add', 'ptr', [ $ap, $sz ] ) ] );
                $builder->emit( 'store_mem_disp', 'void', [ $ap, 0, $psz ] );
                $builder->emit( 'leave_func',     'void', [ $builder->emit( 'add', 'ptr', [ $ap, 8 ] ) ] );
                $builder->emit_label($l_s);

                $builder->emit( 'call_func', 'void', ['M_gc_collect'] );
                my $ap2 = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('heap_ptr') ] );
                my $lp2 = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('heap_limit') ] );
                my $l_f2 = $builder->new_label();
                my $l_s2 = $builder->new_label();
                $builder->emit_cond_br( $builder->emit( 'cmp_lt', 'Int', [ $builder->emit( 'add', 'ptr', [ $ap2, $sz ] ), $lp2 ] ), $l_f2, $l_s2 );
                $builder->emit_label($l_f2);
                $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('heap_ptr'), $builder->emit( 'add', 'ptr', [ $ap2, $sz ] ) ] );
                $builder->emit( 'store_mem_disp', 'void', [ $ap2, 0, $psz ] );
                $builder->emit( 'leave_func',     'void', [ $builder->emit( 'add', 'ptr', [ $ap2, 8 ] ) ] );

                $builder->emit_label($l_s2);
                my $fr = $builder->emit( 'intrinsic_alloc', 'ptr', [$BLOCK_SIZE] );
                my $old_head = $builder->emit('load_iso_disp', 'ptr', [40]);
                $builder->emit('store_mem_disp', 'void', [$fr, 256, $old_head]);
                $builder->emit('store_iso_disp', 'void', [40, $fr]);

                my $st = $builder->emit( 'add', 'ptr', [ $fr, 264 ] );
                $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('heap_ptr'), $builder->emit( 'add', 'ptr', [ $st, $sz ] ) ] );
                $builder->emit( 'store_iso_disp', 'void',
                    [ $driver->iso_offset('heap_limit'), $builder->emit( 'add', 'ptr', [ $fr, $BLOCK_SIZE ] ) ] );
                $builder->emit( 'store_mem_disp', 'void', [ $st, 0, $psz ] );
                $builder->emit( 'leave_func',     'void', [ $builder->emit( 'add', 'ptr', [ $st, 8 ] ) ] );
            }

            # --- [5] Printers ---
            {
                $driver->reset_locals();
                $builder->emit_label('M_print_int');
                $builder->emit( 'enter_func', 'void', [] );
                my $tn   = $builder->emit( 'get_arg', 'i64', [0] );
                my $n    = $builder->emit( 'div',     'i64', [ $builder->emit( 'sub', 'i64', [ $tn, 1 ] ), 2 ] );
                my $l_z  = $builder->new_label();
                my $l_nz = $builder->new_label();
                $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $n, 0 ] ), $l_z, $l_nz );
                $builder->emit_label($l_z);
                $builder->emit( 'intrinsic_print_char', 'void', [48] );
                $builder->emit( 'leave_func',           'void', [0] );
                $builder->emit_label($l_nz);
                my $bf = $builder->emit( 'intrinsic_alloc', 'ptr', [32] );
                my $bs = $driver->alloc_local_slot();
                $builder->emit( 'local_store', 'void', [ $bs, $bf ] );
                my $is = $driver->alloc_local_slot();
                $builder->emit( 'local_store', 'void', [ $is, $builder->emit( 'constant', 'i64', [0] ) ] );
                my $ns = $driver->alloc_local_slot();
                $builder->emit( 'local_store', 'void', [ $ns, $n ] );
                my $l1 = $builder->new_label();
                my $l2 = $builder->new_label();
                $builder->emit_label($l1);
                my $cn = $builder->emit( 'local_load', 'i64', [$ns] );
                my $rm = $builder->emit( 'mod',        'i64', [ $cn, 10 ] );
                $builder->emit(
                    'store_mem_byte',
                    'void',
                    [   $builder->emit( 'local_load', 'ptr', [$bs] ),
                        $builder->emit( 'local_load', 'i64', [$is] ),
                        $builder->emit( 'add',        'i64', [ $rm, 48 ] )
                    ]
                );
                $builder->emit( 'local_store', 'void', [ $is, $builder->emit( 'add', 'i64', [ $builder->emit( 'local_load', 'i64', [$is] ), 1 ] ) ] );
                $builder->emit( 'local_store', 'void', [ $ns, $builder->emit( 'div', 'i64', [ $cn, 10 ] ) ] );
                $builder->emit_cond_br( $builder->emit( 'cmp_gt', 'Int', [ $builder->emit( 'local_load', 'i64', [$ns] ), 0 ] ), $l1, $l2 );
                $builder->emit_label($l2);
                my $l3 = $builder->new_label();
                my $l4 = $builder->new_label();
                $builder->emit_label($l3);
                my $ci = $builder->emit( 'sub', 'i64', [ $builder->emit( 'local_load', 'i64', [$is] ), 1 ] );
                $builder->emit( 'local_store', 'void', [ $is, $ci ] );
                $builder->emit( 'intrinsic_print_char', 'void',
                    [ $builder->emit( 'load_mem_byte', 'Int', [ $builder->emit( 'local_load', 'ptr', [$bs] ), $ci ] ) ] );
                $builder->emit_cond_br( $builder->emit( 'cmp_gt', 'Int', [ $ci, 0 ] ), $l3, $l4 );
                $builder->emit_label($l4);
                $builder->emit( 'leave_func', 'void', [0] );
            }
            {
                $driver->reset_locals();
                $builder->emit_label('M_print_any');
                $builder->emit( 'enter_func', 'void', [] );
                my $v  = $builder->emit( 'get_arg', 'i64', [0] );
                my $is = $builder->emit( 'and',     'i64', [ $v, 1 ] );
                my $lp = $builder->new_label();
                my $li = $builder->new_label();
                my $le = $builder->new_label();
                $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $is, 0 ] ), $lp, $li );
                $builder->emit_label($lp);
                $builder->emit( 'intrinsic_print', 'void', [$v] );
                $builder->emit_jump($le);
                $builder->emit_label($li);
                $builder->emit( 'call_func', 'void', [ 'M_print_int', $v ] );
                $builder->emit_jump($le);
                $builder->emit_label($le);
                $builder->emit( 'leave_func', 'void', [0] );
            }

            # --- [6] Fiber New ---
            {
                $driver->reset_locals();
                $builder->emit_label('M_fiber_new');
                $builder->emit( 'enter_func', 'void', [] );
                my $fp = $builder->emit( 'get_arg', 'i64', [0] );
                my $fs = $driver->alloc_local_slot();
                $builder->emit( 'local_store', 'void', [ $fs, $fp ] );
                my $leaf_64  = $builder->emit( 'constant',  'i64', [ 64 | hex("2000000000000000") ] );
                my $leaf_64k = $builder->emit( 'constant',  'i64', [ 65536 | hex("2000000000000000") ] );
                my $fb       = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', $leaf_64 ] );
                my $bs       = $driver->alloc_local_slot();
                $builder->emit( 'local_store', 'void', [ $bs, $fb ] );
                my $ms = $builder->emit( 'intrinsic_alloc', 'ptr', [65536] );
                my $cf = $builder->emit( 'local_load',      'ptr', [$bs] );
                my $tp = $builder->emit( 'add',             'ptr', [ $ms, 65536 ] );
                $builder->emit( 'store_mem_disp', 'void', [ $cf, $driver->fcb_offset('stack_base'),  $tp ] );
                $builder->emit( 'store_mem_disp', 'void', [ $cf, $driver->fcb_offset('stack_limit'), $ms ] );
                my $rl = $builder->emit( 'sub', 'ptr', [ $tp, 8 ] );
                $builder->emit( 'store_mem_disp', 'void', [ $rl, 0, $builder->emit( 'local_load', 'i64', [$fs] ) ] );
                my $cs = $driver->context_size();
                my $rb = $builder->emit( 'sub', 'ptr', [ $rl, $cs ] );
                for ( my $o = 0; $o < $cs; $o += 8 ) { $builder->emit( 'store_mem_disp', 'void', [ $rb, $o, 0 ] ); }
                $builder->emit( 'store_mem_disp', 'void',
                    [ $rb, $driver->context_offset( ( $driver->arch eq 'x64' ? 'r14' : 'x27' ) ), $builder->emit( 'get_isolate_ctx', 'ptr', [] ) ] );
                $builder->emit( 'store_mem_disp', 'void', [ $rb, $driver->context_offset( ( $driver->arch eq 'x64' ? 'rbp' : 'x29' ) ), $rb ] );
                my $sh = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', $leaf_64k ] );
                $cf = $builder->emit( 'local_load', 'ptr', [$bs] );
                $builder->emit( 'store_mem_disp', 'void', [ $cf, $driver->fcb_offset('shadow_base'), $sh ] );
                $builder->emit( 'store_mem_disp', 'void', [ $cf, $driver->fcb_offset('shadow_ptr'),  $sh ] );
                my $is = $builder->emit( 'get_isolate_ctx', 'ptr', [] );
                $builder->emit( 'store_mem_disp', 'void',
                    [ $cf, $driver->fcb_offset('next'), $builder->emit( 'load_mem_disp', 'ptr', [ $is, $driver->iso_offset('fiber_head') ] ) ] );
                $builder->emit( 'store_mem_disp', 'void', [ $is, $driver->iso_offset('fiber_head'), $cf ] );
                $builder->emit( 'store_mem_disp', 'void', [ $cf, $driver->fcb_offset('sp'),         $rb ] );
                $builder->emit( 'leave_func',     'void', [$cf] );
            }
        }

        # --- AST Visitor ---
        method lower_Const($node) {
            if ( $node->type eq 'String' ) {
                return ( $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string( $node->value ) ] ), 'String' );
            }
            if ( $node->type eq 'Class' ) { return ( $builder->emit( 'constant', 'i64', [0] ), $node->value ); }
            return ( $builder->emit( 'constant', 'i64', [ ( $node->value << 1 ) | 1 ] ), 'Int' );
        }

        method lower_Var($node) {
            my $sym = $current_scope->resolve( $node->name ) // die "Undeclared " . $node->name;
            if ( defined $sym->stack_offset && $sym->stack_offset < 0 ) {
                my $sp = $builder->emit( 'local_load', 'ptr', [ $current_scope->resolve('$self')->stack_offset ] );
                return ( $builder->emit( 'load_mem_disp', 'Any', [ $sp, abs( $sym->stack_offset ) ] ), 'Any' );
            }
            if ( $sym->is_state ) {
                my $sb = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('state_ptr') ] );
                return ( $builder->emit( 'load_mem_disp', $sym->type, [ $sb, 4096 + ( $sym->state_idx * 8 ) ] ), $sym->type );
            }
            return ( $builder->emit( 'local_load', $sym->type, [ $sym->stack_offset ] ), $sym->type );
        }

        method lower_VarDecl($node) {
            my ( $vr, $vt ) = $self->lower( $node->value );
            my $sl = $driver->alloc_local_slot();
            $current_scope->define( $node->name, $node->type eq 'Any' ? $vt : $node->type, 0, undef, $sl );
            $builder->emit( 'local_store', 'void', [ $sl, $vr ] );
            return ( undef, 'void' );
        }

        method lower_StateDecl($node) {
            my $idx = $state_count++;
            $current_scope->define( $node->name, $node->type, 1, $idx, undef );
            my $l_i = $builder->new_label();
            my $l_d = $builder->new_label();
            my $sb  = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('state_ptr') ] );
            $builder->emit_cond_br( $builder->emit( 'load_mem_byte', 'Int', [ $sb, $idx ] ), $l_d, $l_i );
            $builder->emit_label($l_i);
            my ( $vr, $vt ) = $self->lower( $node->value );
            $builder->emit( 'store_mem_byte', 'void', [ $sb, $idx, 1 ] );
            $builder->emit( 'store_mem_disp', 'void', [ $sb, 4096 + ( $idx * 8 ), $vr ] );
            $builder->emit_jump($l_d);
            $builder->emit_label($l_d);
            return ( $builder->emit( 'load_mem_disp', $node->type, [ $sb, 4096 + ( $idx * 8 ) ] ), $node->type );
        }

        method lower_Assignment($node) {
            my ( $vr, $vt ) = $self->lower( $node->value );
            my $sym = $current_scope->resolve( $node->name ) // die "Undeclared " . $node->name;
            if ( defined $sym->stack_offset && $sym->stack_offset < 0 ) {
                my $sp = $builder->emit( 'local_load', 'ptr', [ $current_scope->resolve('$self')->stack_offset ] );
                $builder->emit( 'store_mem_disp', 'void', [ $sp, abs( $sym->stack_offset ), $vr ] );
            }
            elsif ( $sym->is_state ) {
                my $sb = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('state_ptr') ] );
                $builder->emit( 'store_mem_disp', 'void', [ $sb, 4096 + ( $sym->state_idx * 8 ), $vr ] );
            }
            else { $builder->emit( 'local_store', 'void', [ $sym->stack_offset, $vr ] ); }
            return ( $vr, $sym->type );
        }

        method lower_UnaryOp($node) {
            my ( $r, $t ) = $self->lower( $node->expr );
            if ( $node->op eq '!' ) {
                my $raw = $builder->emit( 'cmp_eq', 'Int', [ $r, 1 ] );
                return ( $builder->emit( 'add', 'i64', [ $builder->emit( 'mul', 'i64', [ $raw, 2 ] ), 1 ] ), 'Int' );
            }
            die "Unary " . $node->op;
        }

        method lower_BinOp($node) {
            if ( $node->op eq '&&' || $node->op eq '||' ) { return $self->_lower_logical($node); }
            my ( $lr, $lt ) = $self->lower( $node->left );
            my ( $rr, $rt ) = $self->lower( $node->right );
            my $cm = { '==' => 'cmp_eq', '!=' => 'cmp_ne', '<' => 'cmp_lt', '>' => 'cmp_gt', '<=' => 'cmp_le', '>=' => 'cmp_ge' };
            if ( exists $cm->{ $node->op } ) {
                my $raw = $builder->emit( $cm->{ $node->op }, 'i64', [ $lr, $rr ] );
                return ( $builder->emit( 'add', 'i64', [ $builder->emit( 'mul', 'i64', [ $raw, 2 ] ), 1 ] ), 'Int' );
            }
            my $mm  = { '+' => 'add', '-' => 'sub', '*' => 'mul', '/' => 'div', '%' => 'mod' };
            my $c1  = $builder->emit( 'constant',         'i64', [1] );
            my $c2  = $builder->emit( 'constant',         'i64', [2] );
            my $lu  = $builder->emit( 'div',              'i64', [ $builder->emit( 'sub', 'i64', [ $lr, $c1 ] ), $c2 ] );
            my $ru  = $builder->emit( 'div',              'i64', [ $builder->emit( 'sub', 'i64', [ $rr, $c1 ] ), $c2 ] );
            my $res = $builder->emit( $mm->{ $node->op }, 'i64', [ $lu, $ru ] );
            return ( $builder->emit( 'add', 'i64', [ $builder->emit( 'mul', 'i64', [ $res, $c2 ] ), $c1 ] ), 'Int' );
        }

        method lower_Ternary($node) {
            my $rs = $driver->alloc_local_slot();
            my $l1 = $builder->new_label();
            my $l2 = $builder->new_label();
            my $l3 = $builder->new_label();
            $builder->emit_cond_br( $self->_emit_bool_test( ( $self->lower( $node->cond ) )[0] ), $l1, $l2 );
            $builder->emit_label($l1);
            $builder->emit( 'local_store', 'void', [ $rs, ( $self->lower( $node->then ) )[0] ] );
            $builder->emit_jump($l3);
            $builder->emit_label($l2);
            $builder->emit( 'local_store', 'void', [ $rs, ( $self->lower( $node->else ) )[0] ] );
            $builder->emit_label($l3);
            return ( $builder->emit( 'local_load', 'Any', [$rs] ), 'Any' );
        }

        method lower_Block($node) {

            # SCOPED SHADOW STACK HEIGHT
            my $sp_backup = $builder->emit( 'shadow_get', 'ptr', [] );
            $current_scope = Brocken::Scope->new( parent => $current_scope );
            my @res = $self->lower_block( $node->statements );
            $current_scope = $current_scope->parent;
            $builder->emit( 'shadow_set', 'void', [$sp_backup] );
            return @res;
        }

        method lower_If($node) {
            my $l1 = $builder->new_label();
            my $l2 = $builder->new_label();
            my $l3 = $builder->new_label();
            $builder->emit_cond_br( $self->_emit_bool_test( ( $self->lower( $node->condition ) )[0] ), $l1, $l2 );
            $builder->emit_label($l1);
            $self->lower( $node->then_block );
            $builder->emit_jump($l3);
            $builder->emit_label($l2);
            $self->lower( $node->else_block ) if $node->else_block;
            $builder->emit_label($l3);
            return ( undef, 'void' );
        }

        method lower_While($node) {
            my $l1 = $builder->new_label();
            my $l2 = $builder->new_label();
            my $l3 = $builder->new_label();
            $builder->emit_label($l1);
            $builder->emit_cond_br( $self->_emit_bool_test( ( $self->lower( $node->condition ) )[0] ), $l2, $l3 );
            $builder->emit_label($l2);
            $self->lower( $node->body );
            $builder->emit_jump($l1);
            $builder->emit_label($l3);
            return ( undef, 'void' );
        }

        method lower_Call($node) {
            if ( $node->name eq 'transfer' ) {
                return (
                    $builder->emit(
                        'call_func', 'Int', [ 'M_fiber_switch', ( $self->lower( $node->args->[0] ) )[0], ( $self->lower( $node->args->[1] ) )[0] ]
                    ),
                    'Any'
                );
            }
            if ( $node->name =~ /^(say|print)$/ ) {
                my ( $r, $t ) = $self->lower( $node->args->[0] );
                if    ( $t eq 'String' ) { $builder->emit( 'intrinsic_print', 'void', [$r] ); }
                elsif ( $t eq 'Int' )    { $builder->emit( 'call_func',       'void', [ 'M_print_int', $r ] ); }
                else                     { $builder->emit( 'call_func',       'void', [ 'M_print_any', $r ] ); }
                if ( $node->name eq 'say' ) {
                    $builder->emit( 'intrinsic_print', 'void', [ $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string("\
") ] ) ] );
                }
                return ( undef, 'void' );
            }
            my $sp_backup = $builder->emit( 'shadow_get', 'ptr', [] );
            my @args      = map { ( $self->lower($_) )[0] } @{ $node->args };
            my $res       = $builder->emit( 'call_func', 'i64', [ 'M_' . $node->name, @args ] );
            $builder->emit( 'shadow_set', 'void', [$sp_backup] );
            return ( $res, 'Any' );
        }

        method lower_Defer($node) {
            my @saved_instructions = $builder->instructions;
            $builder->set_instructions(); # Clear temporarily
            $self->lower($node->block);
            my @deferred_instructions = $builder->instructions;
            $builder->set_instructions(@saved_instructions); # Restore
            push @defer_stack, \@deferred_instructions;
            return (undef, 'void');
        }
        method lower_Return($node) {
            die "Return outside sub" if $routine_depth == 0;
            my ( $rv, $ty ) = $self->lower( $node->expr );
            $self->_emit_all_defers();
            if ( $routine_types[-1] eq 'fiber' ) {
                my $fcb = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('current_fcb') ] );
                $builder->emit( 'call_func', 'Any',
                    [ 'M_fiber_switch', $builder->emit( 'load_mem_disp', 'ptr', [ $fcb, $driver->fcb_offset('caller') ] ), $rv ] );
                $builder->emit( 'intrinsic_exit', 'void', [0] );
            }
            else { $builder->emit( 'leave_func', 'void', [$rv] ); }
            return ( undef, 'void' );
        }
        method lower_Exit($node) {  $self->_emit_all_defers(); $builder->emit( 'intrinsic_exit', 'void', [ ( $self->lower( $node->expr ) )[0] ] ); return ( undef, 'void' ); }

        method lower_ClassDecl($node) {
            my $ci = $class_info{ $node->name };
            my %fm;
            my $off = 16;
            for my $f ( @{ $node->fields } ) { $fm{ $f->name } = $off; $off += 8; }
            $driver->reset_locals();
            $builder->emit_label( 'M_' . $node->name . '::new' );
            $builder->emit( 'enter_func', 'void', [] );
            my $obj = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', $builder->emit( 'constant', 'i64', [$off] ) ] );
            $builder->emit(
                'store_mem_disp',
                'void',
                [   $obj, 0,
                    $builder->emit(
                        'load_mem_disp', 'ptr', [ $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('state_ptr') ] ), $ci->{id} * 8 ]
                    )
                ]
            );
            $builder->emit( 'store_mem_disp', 'void', [ $obj, 8, $builder->emit( 'constant', 'i64', [1] ) ] );
            $builder->emit( 'leave_func',     'void', [$obj] );
            push @routine_types, 'method';

            for my $m ( @{ $node->methods } ) {
                $driver->reset_locals();
                $builder->emit_label( 'M_' . $node->name . '::' . $m->name );
                $builder->emit( 'enter_func', 'void', [] );
                $current_scope = Brocken::Scope->new( parent => $current_scope );
                $routine_depth++;
                my $ss = $driver->alloc_local_slot();
                $current_scope->define( '$self', 'ptr', 0, undef, $ss );
                $builder->emit( 'local_store', 'void', [ $ss, $builder->emit( 'get_arg', 'ptr', [0] ) ] );
                for my $fn ( keys %fm ) { $current_scope->define( $fn, 'Any', 0, undef, -$fm{$fn} ); }
                my $ai = 1;

                for my $p ( @{ $m->params } ) {
                    my $sl = $driver->alloc_local_slot();
                    $current_scope->define( $p->{name}, $p->{type}, 0, undef, $sl );
                    $builder->emit( 'local_store', 'void', [ $sl, $builder->emit( 'get_arg', 'i64', [ $ai++ ] ) ] );
                }
                $self->lower_block( $m->body->statements );
                 $self->_emit_all_defers();
                $builder->emit( 'leave_func', 'void', [0] );
                $routine_depth--;
                $current_scope = $current_scope->parent;
            }
            pop @routine_types;
            return ( undef, 'void' );
        }

        method lower_Method($node) {
            push @routine_types, 'method';
            my @old_defers = @defer_stack;
            @defer_stack = ();
            $driver->reset_locals();
            $builder->emit_label( 'M_' . $node->name );
            $builder->emit( 'enter_func', 'void', [] );
            $current_scope = Brocken::Scope->new( parent => $current_scope );
            $routine_depth++;
            my $ai = 0;
            for my $p ( @{ $node->params } ) {
                my $sl = $driver->alloc_local_slot();
                $current_scope->define( $p->{name}, $p->{type}, 0, undef, $sl );
                $builder->emit( 'local_store', 'void', [ $sl, $builder->emit( 'get_arg', 'i64', [ $ai++ ] ) ] );
            }
            $self->lower_block( $node->body->statements );
$self->_emit_all_defers();
$builder->emit( 'leave_func', 'void', [0] );
            $routine_depth--;
            $current_scope = $current_scope->parent;
            @defer_stack = @old_defers;
            pop @routine_types;
            return ( undef, 'void' );
        }

        method lower_MethodCall($node) {
            if ( $node->name eq 'new' && $node->invocant isa Brocken::AST::Expr::Const && $node->invocant->type eq 'Class' ) {
                my $ptr = $builder->emit( 'call_func', 'ptr', [ 'M_' . $node->invocant->value . '::new' ] );
                $builder->emit( 'shadow_push', 'void', [$ptr] );
                return ( $ptr, $node->invocant->value );
            }
            my $sp_backup = $builder->emit( 'shadow_get', 'ptr', [] );
            my ( $or, $ot ) = $self->lower( $node->invocant );
            my @as  = map { ( $self->lower($_) )[0] } @{ $node->args };
            my $vt  = $builder->emit( 'load_mem_disp', 'ptr', [ $or, 0 ] );
            my $fn  = $builder->emit( 'load_mem_disp', 'ptr', [ $vt, ( $global_methods{ $node->name } // die $node->name ) * 8 ] );
            my $res = $builder->emit( 'call_reg',      'i64', [ $fn, $or, @as ] );
            $builder->emit( 'shadow_set', 'void', [$sp_backup] );
            return ( $res, 'Any' );
        }

        method lower_FiberBlock($node) {
            my $l1 = $builder->new_label();
            my $l2 = $builder->new_label();
            $builder->emit_jump($l2);
            my @saved = $builder->instructions;
            $builder->set_instructions();
            my $op = $driver->local_ptr;
            $driver->reset_locals();
            $builder->emit_label($l1);
            $builder->emit( 'enter_func', 'void', [] );
            $current_scope = Brocken::Scope->new( parent => $current_scope );
            $routine_depth++;
            push @routine_types, 'fiber';

            if ( scalar @{ $node->params } > 0 ) {
                my $sl = $driver->alloc_local_slot();
                $current_scope->define( $node->params->[0]{name}, $node->params->[0]{type}, 0, undef, $sl );
                $builder->emit( 'local_store', 'void', [ $sl, $builder->emit( 'mov', 'Any', ['rax'] ) ] );
            }
            my ( $res, $ty ) = $self->lower_block( $node->body->statements );
            my $fcb = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('current_fcb') ] );
            $builder->emit( 'call_func', 'Any',
                [ 'M_fiber_switch', $builder->emit( 'load_mem_disp', 'ptr', [ $fcb, $driver->fcb_offset('caller') ] ), $res // 3 ] );
            $builder->emit( 'intrinsic_exit', 'void', [0] );
            pop @routine_types;
            $routine_depth--;
            $current_scope = $current_scope->parent;
            my @ir = $builder->instructions;
            $builder->set_instructions( @saved, @ir );
            $builder->emit_label($l2);
            $driver->set_local_ptr($op);
            return ( $builder->emit( 'call_func', 'ptr', [ 'M_fiber_new', $l1 ] ), 'Fiber' );
        }

        method lower_Yield($node) {
            my $fcb = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('current_fcb') ] );
            return (
                $builder->emit(
                    'call_func',
                    'Int',
                    [   'M_fiber_switch',
                        $builder->emit( 'load_mem_disp', 'ptr', [ $fcb, $driver->fcb_offset('caller') ] ),
                        ( $self->lower( $node->expr ) )[0]
                    ]
                ),
                'Int'
            );
        }

        method lower_ArrayLiteral($node) {
            my $ct  = scalar @{ $node->elements };
            my $sz  = 8 + ( $ct * 8 );
            my $arr = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', $builder->emit( 'constant', 'i64', [ $sz | hex("4000000000000000") ] ) ] );
            $builder->emit( 'shadow_push',    'void', [$arr] );
            $builder->emit( 'store_mem_disp', 'void', [ $arr, 0, $builder->emit( 'constant', 'i64', [ ( $ct << 1 ) | 1 ] ) ] );
            my $ix = 0;
            for my $el ( @{ $node->elements } ) { $builder->emit( 'store_mem_disp', 'void', [ $arr, 8 + ( $ix++ * 8 ), ( $self->lower($el) )[0] ] ); }
            return ( $arr, 'Array' );
        }
        method lower_Map($node) { return ( $builder->emit( 'map_op', 'Array', [ ( $self->lower( $node->source ) )[0], $node->expr ] ), 'Array' ); }

        method lower_AnonSub($node) {
            my $lb = "L_ANON_" . ++$anon_counter;
            my $op = $driver->local_ptr;
            $self->capture_fragment(
                $lb,
                sub {
                    $driver->reset_locals();
                    $builder->emit_label($lb);
                    $builder->emit( 'enter_func', 'void', [] );
                    $current_scope = Brocken::Scope->new( parent => $current_scope );
                    $routine_depth++;
                    my $ai = 0;
                    for my $p ( @{ $node->params } ) {
                        my $sl = $driver->alloc_local_slot();
                        $current_scope->define( $p->{name}, $p->{type}, 0, undef, $sl );
                        $builder->emit( 'local_store', 'void', [ $sl, $builder->emit( 'get_arg', 'i64', [ $ai++ ] ) ] );
                    }
                    $self->lower_block( $node->body->statements );
                     $self->_emit_all_defers();
                    $builder->emit( 'leave_func', 'void', [0] );
                    $routine_depth--;
                    $current_scope = $current_scope->parent;
                }
            );
            $driver->set_local_ptr($op);
            return ( $builder->emit( 'load_func_addr', 'ptr', [$lb] ), 'ptr' );
        }

        method lower_AnonCall($node) {
            return (
                $builder->emit( 'call_reg', 'i64', [ ( $self->lower( $node->invocant ) )[0], map { ( $self->lower($_) )[0] } @{ $node->args } ] ),
                'Any' );
        }

    }
}
1;
