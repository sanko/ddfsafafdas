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
        field $current_scope     = Brocken::Scope->new();
        field $state_count       = 0;
        field $routine_depth     = 0;
        field $current_func_name = undef;
        field @func_locals;
        field @routine_types = ('main');
        field %class_info;
        field %global_methods;
        field $global_method_count = 0;
        field $class_id_counter    = 0;
        method class_info () { return %class_info }
        field $anon_counter = 0;
        field @fragments;
        field @defer_stack;               # Stack of [ \@instructions ]
        field $defer_active_depth = 0;    # Helper to prevent return inside of defer block
        my $BLOCK_SIZE = 65536;
        my $LINE_SIZE  = 128;
        my $LINE_COUNT = 512;

        # Helpers
        method _emit_bool_test($reg) {

            # In Brocken Smi: False is 1, True is 3. CPU needs 0/1.
            return $builder->emit( 'cmp_ne', 'Int', [ $reg, $builder->emit( 'constant', 'i64', [1] ) ] );
        }

        method _collect_local ( $name, $type, $slot ) {
            if ( defined $current_func_name && $driver->debug >= 3 ) {
                push @func_locals, { name => $name, type => $type, slot => $slot };
            }
        }

        method _flush_func_locals () {
            if ( defined $current_func_name && $driver->debug >= 3 ) {
                $driver->set_debug_func_locals( $current_func_name, [@func_locals] );
                $current_func_name = undef;
                @func_locals       = ();
            }
        }

        method _emit_all_defers() {

            # LIFO: Reverse the stack of currently deferred actions
            # We use a copy to avoid modification issues during iteration
            my @current = reverse @defer_stack;
            for my $fragment (@current) {
                $builder->push_instruction($_) for @$fragment;
            }
        }

        method _lower_logical($node) {
            my $op       = $node->op;
            my $res_slot = $driver->alloc_local_slot();
            my $l_end    = $builder->new_label();
            my ( $l_reg, $l_typ ) = $self->lower( $node->left );
            $builder->emit( 'local_store', 'void', [ $res_slot, $l_reg ] );
            my $cond_reg;
            if ( $op eq '//' ) {

                # Defined-OR: short-circuit if LEFT is NOT 0 (undef)
                $cond_reg = $builder->emit( 'cmp_ne', 'Int', [ $l_reg, 0 ] );
            }
            else {
                # Logical OR/AND: uses _emit_bool_test (Smi false = 1, pointers/other = true)
                $cond_reg = $self->_emit_bool_test($l_reg);
            }
            if ( $op eq '&&' ) {

                # AND: short-circuit to end if FALSE (result is left value)
                $builder->emit_cond_br( $cond_reg, $builder->new_label(), $l_end );
            }
            else {
                # OR / Defined-OR: short-circuit to end if TRUE (result is left value)
                $builder->emit_cond_br( $cond_reg, $l_end, $builder->new_label() );
            }
            $builder->emit_label( $builder->last_instruction->{ ( $op eq '&&' ? 'true_l' : 'false_l' ) } );
            my ( $r_reg, $r_typ ) = $self->lower( $node->right );
            $builder->emit( 'local_store', 'void', [ $res_slot, $r_reg ] );
            $builder->emit_label($l_end);
            return ( $builder->emit( 'local_load', 'Any', [$res_slot] ), 'Any' );
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
            for my $stmt ( grep {defined} @$statements ) {
                if ( $driver->debug >= 1 ) {
                    $builder->emit( 'source_loc', 'void', [ $stmt->line, $stmt->col ] );
                }
                ( $reg, $type ) = $self->lower($stmt);
            }
            return ( $reg, $type );
        }

        method _lower_fiber_new_runtime() {
            $driver->reset_locals();
            $builder->emit_label('M_fiber_new');
            $builder->emit( 'enter_func', 'void', [] );
            my $sh_init = $builder->emit( 'shadow_get', 'ptr', [] );

            # Arg 0: Start Address of the fiber logic
            my $func_ptr = $builder->emit( 'get_arg', 'i64', [0] );
            my $fp_slot  = $driver->alloc_local_slot();
            $builder->emit( 'local_store', 'void', [ $fp_slot, $func_ptr ] );

            # 1. Allocate Fiber Control Block (64 bytes, Leaf marked)
            my $fcb_size_tagged = $builder->emit( 'constant',  'i64', [ 64 | hex("2000000000000000") ] );
            my $fb              = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', $fcb_size_tagged ] );
            $builder->emit( 'shadow_push', 'void', [$fb] );    # Protect it!
            my $fb_slot = $driver->alloc_local_slot();
            $builder->emit( 'local_store', 'void', [ $fb_slot, $fb ] );

            # 2. Create the OS Wait Handle (Windows Event / Linux Pipe)
            # This is the handle sleep() will wait on and interrupt() will trigger
            my $handle = $builder->emit( 'intrinsic_create_wait_handle', 'ptr', [] );
            $builder->emit( 'store_mem_disp', 'void', [ $fb, $driver->fcb_offset('wait_handle'), $handle ] );

            # 3. Allocate the Fiber's Private Stack (64KB)
            my $stack_mem = $builder->emit( 'intrinsic_alloc', 'ptr', [65536] );
            my $tp        = $builder->emit( 'add',             'ptr', [ $stack_mem, 65536 ] );

            # Align stack to 16 bytes (ABI requirement)
            $tp = $builder->emit( 'and', 'i64', [ $tp, $builder->emit( 'constant', 'i64', [ hex("FFFFFFFFFFFFFFF0") ] ) ] );

            # 4. Prepare the initial stack frame
            # On x64, we reserve shadow space (32) + 8 for return address
            my $gap      = ( $driver->arch eq 'x64' ) ? 48 : 0;
            my $rsp_init = $builder->emit( 'sub', 'ptr', [ $tp, $gap ] );

            # Store the fiber entry point into the "Return Address" slot
            $builder->emit( 'store_mem_disp', 'void', [ $rsp_init, 0, $builder->emit( 'local_load', 'i64', [$fp_slot] ) ] );

            # 5. Save initial Context (Registers)
            my $cs = $driver->context_size();
            my $rb = $builder->emit( 'sub', 'ptr', [ $rsp_init, $cs ] );
            for ( my $o = 0; $o < $cs; $o += 8 ) {
                $builder->emit( 'store_mem_disp', 'void', [ $rb, $o, 0 ] );
            }

            # CRITICAL: New fibers MUST inherit the Isolate Context (R14/X28)!
            my $iso_val  = $builder->emit( 'get_isolate_ctx', 'ptr', [] );
            my $regs     = $driver->preserved_regs();
            my @rev_regs = reverse @$regs;
            for ( my $i = 0; $i < @rev_regs; $i++ ) {
                if ( $rev_regs[$i] =~ /^(r14|x28)$/ ) {
                    $builder->emit( 'store_mem_disp', 'void', [ $rb, $i * 8, $iso_val ] );
                }
            }

            # 6. Initialize Fiber Shadow Stack (16KB) for GC
            my $shad_size_tagged = $builder->emit( 'constant',  'i64', [ 16384 | hex("2000000000000000") ] );
            my $sh               = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', $shad_size_tagged ] );

            # 7. Finalize FCB Fields
            my $cf = $builder->emit( 'local_load', 'ptr', [$fb_slot] );
            $builder->emit( 'store_mem_disp', 'void', [ $cf, $driver->fcb_offset('shadow_base'), $sh ] );
            $builder->emit( 'store_mem_disp', 'void', [ $cf, $driver->fcb_offset('shadow_ptr'),  $sh ] );
            $builder->emit( 'store_mem_disp', 'void', [ $cf, $driver->fcb_offset('stack_base'),  $tp ] );
            $builder->emit( 'store_mem_disp', 'void', [ $cf, $driver->fcb_offset('sp'),          $rb ] );

            # Link into Isolate Fiber List
            my $is = $builder->emit( 'get_isolate_ctx', 'ptr', [] );
            $builder->emit( 'store_mem_disp', 'void',
                [ $cf, $driver->fcb_offset('next'), $builder->emit( 'load_mem_disp', 'ptr', [ $is, $driver->iso_offset('fiber_head') ] ) ] );
            $builder->emit( 'store_mem_disp', 'void', [ $is, $driver->iso_offset('fiber_head'), $cf ] );
            $builder->emit( 'shadow_set',     'void', [$sh_init] );
            $builder->emit( 'leave_func',     'void', [$cf] );
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
            $builder->emit( 'store_mem_disp', 'void', [ $iso_reg, 80, $builder->emit( 'constant', 'i64', [1] ) ] );    # Init GC Cycle
            my $c128k     = $builder->emit( 'constant',        'i64', [131072] );
            my $c64k      = $builder->emit( 'constant',        'i64', [65536] );
            my $raw_heap  = $builder->emit( 'intrinsic_alloc', 'ptr', [$c128k] );
            my $init_heap = $builder->emit(
                'and', 'i64',
                [   $builder->emit( 'add',      'ptr', [ $raw_heap, $builder->emit( 'constant', 'i64', [65535] ) ] ),
                    $builder->emit( 'constant', 'i64', [-65536] )
                ]
            );
            $builder->emit( 'store_iso_disp', 'void', [ 40, $init_heap ] );
            $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('heap_min'), $init_heap ] );
            my $hmax = $builder->emit( 'add', 'ptr', [ $init_heap, $c64k ] );
            $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('heap_max'), $hmax ] );

            # Store next link (0) at offset 0
            $builder->emit( 'store_mem_disp', 'void', [ $init_heap, 0, $builder->emit( 'constant', 'i64', [0] ) ] );

            # Objects start at 1024 to leave room for the full bitmap
            my $first_line = $builder->emit( 'add', 'ptr', [ $init_heap, 1024 ] );
            $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('heap_ptr'),   $first_line ] );
            $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('heap_limit'), $builder->emit( 'add', 'ptr', [ $init_heap, $c64k ] ) ] );
            my $state_mem = $builder->emit( 'intrinsic_alloc', 'ptr', [1048576] );
            $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('state_ptr'), $state_mem ] );

            # VTable Generation
            for my $cname ( sort keys %class_info ) {
                my $c           = $class_info{$cname};
                my $ptr_count   = scalar @{ $c->{ptr_offsets} };
                my $vt_raw      = $builder->emit( 'intrinsic_alloc', 'ptr', [ ( 1 + $ptr_count ) * 8 + ( $global_method_count * 8 ) ] );
                my $method_base = $builder->emit( 'add',             'ptr', [ $vt_raw, ( 1 + $ptr_count ) * 8 ] );
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
            # --- Initialize "Main" Fiber ---
            my $leaf_64  = $builder->emit( 'constant',  'i64', [ 64 | hex("2000000000000000") ] );
            my $main_fcb = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', $leaf_64 ] );

            # Link it immediately! So it survives if next alloc triggers GC
            $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('current_fcb'), $main_fcb ] );
            $builder->emit( 'store_mem_disp', 'void',
                [ $builder->emit( 'get_isolate_ctx', 'ptr', [] ), $driver->iso_offset('fiber_head'), $main_fcb ] );

            # Zero out fields so GC doesn't follow junk
            $builder->emit( 'store_mem_disp', 'void', [ $main_fcb, $driver->fcb_offset('shadow_base'), 0 ] );
            $builder->emit( 'store_mem_disp', 'void', [ $main_fcb, $driver->fcb_offset('shadow_ptr'),  0 ] );
            $builder->emit( 'store_mem_disp', 'void', [ $main_fcb, $driver->fcb_offset('next'),        0 ] );

            # --- START: NEW BIT FOR INTERRUPTIBLE SLEEP ---
            my $m_handle = $builder->emit( 'intrinsic_create_wait_handle', 'ptr', [] );
            $builder->emit( 'store_mem_disp', 'void', [ $main_fcb, $driver->fcb_offset('wait_handle'), $m_handle ] );

            # --- END: NEW BIT ---
            my $leaf_16k  = $builder->emit( 'constant',  'i64', [ 16384 | hex("2000000000000000") ] );
            my $main_shad = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', $leaf_16k ] );
            $builder->emit( 'store_mem_disp', 'void', [ $main_fcb, $driver->fcb_offset('shadow_base'), $main_shad ] );
            $builder->emit( 'store_mem_disp', 'void', [ $main_fcb, $driver->fcb_offset('shadow_ptr'),  $main_shad ] );
            $builder->emit( 'store_mem_disp', 'void', [ $main_fcb, $driver->fcb_offset('caller'),      $builder->emit( 'constant', 'i64', [0] ) ] );
            $current_func_name = 'L_MAIN_START';
            @func_locals       = ();
            $self->lower_block( \@main_stmts );
            $self->_flush_func_locals();
            $self->_emit_all_defers();    # Support top-level defer

            # EXPLICIT EXIT 0 to prevent CPU from falling through into M_fiber_switch !
            $builder->emit( 'intrinsic_exit', 'void', [ $builder->emit( 'constant', 'i64', [1] ) ] );
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

            # --- [1] M_gc_mark_obj inside inject_runtime() ---
            {
                $driver->reset_locals();
                $builder->emit_label('M_gc_mark_obj');
                $builder->emit( 'enter_func', 'void', [] );
                my $obj   = $builder->emit( 'get_arg', 'ptr', [0] );
                my $l_end = $builder->new_label();
                $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $obj, 0 ] ), $l_end, $builder->new_label() );
                $builder->emit_label( $builder->last_instruction->{false_l} );
                $builder->emit_cond_br( $builder->emit( 'and', 'i64', [ $obj, 1 ] ), $l_end, $builder->new_label() );
                $builder->emit_label( $builder->last_instruction->{false_l} );

                # Range check: Only objects in Immix blocks are marked and traced
                my $hmin = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('heap_min') ] );
                my $hmax = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('heap_max') ] );
                $builder->emit_cond_br( $builder->emit( 'cmp_lt', 'Int', [ $obj, $hmin ] ), $l_end, $builder->new_label() );
                $builder->emit_label( $builder->last_instruction->{false_l} );
                $builder->emit_cond_br( $builder->emit( 'cmp_ge', 'Int', [ $obj, $hmax ] ), $l_end, $builder->new_label() );
                $builder->emit_label( $builder->last_instruction->{false_l} );
                my $header    = $builder->emit( 'load_mem_disp', 'i64', [ $obj, -8 ] );
                my $cycle     = $builder->emit( 'load_iso_disp', 'i64', [80] );
                my $obj_cycle = $builder->emit( 'and',           'i64', [ $builder->emit( 'shr', 'i64', [ $header, 32 ] ), 0xFFFFFF ] );
                $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $obj_cycle, $cycle ] ), $l_end, $builder->new_label() );
                $builder->emit_label( $builder->last_instruction->{false_l} );

                # Mark header with current cycle
                my $new_hdr = $builder->emit( 'or', 'i64',
                    [ $builder->emit( 'and', 'i64', [ $header, hex("FF000000FFFFFFFF") ] ), $builder->emit( 'shl', 'i64', [ $cycle, 32 ] ) ] );
                $builder->emit( 'store_mem_disp', 'void', [ $obj, -8, $new_hdr ] );

                # Immix Bitmap Line Marking (FIXED: Loop over all lines the object occupies)
                my $block      = $builder->emit( 'and', 'i64', [ $obj, -$BLOCK_SIZE ] );
                my $off        = $builder->emit( 'sub', 'i64', [ $obj, $block ] );
                my $start_line = $builder->emit( 'shr', 'i64', [ $off, 7 ] );
                my $obj_sz     = $builder->emit( 'and', 'i64', [ $header, hex("1FFFFFFFFFFFFFFF") ] );
                my $num_lines  = $builder->emit( 'div', 'i64', [ $builder->emit( 'add', 'i64', [ $obj_sz, 135 ] ), 128 ] );
                my $ml_slot    = $driver->alloc_local_slot();
                $builder->emit( 'local_store', 'void', [ $ml_slot, 0 ] );
                my $l_mloop = $builder->new_label();
                my $l_mdone = $builder->new_label();
                $builder->emit_label($l_mloop);
                my $mi = $builder->emit( 'local_load', 'i64', [$ml_slot] );
                $builder->emit_cond_br( $builder->emit( 'cmp_lt', 'Int', [ $mi, $num_lines ] ), $builder->new_label(), $l_mdone );
                $builder->emit_label( $builder->last_instruction->{true_l} );
                my $line_to_mark = $builder->emit( 'add', 'i64', [ $builder->emit( 'add', 'i64', [ $start_line, $mi ] ), 8 ] );
                $builder->emit( 'store_mem_byte', 'void', [ $block, $line_to_mark, 1 ] );
                $builder->emit( 'local_store', 'void', [ $ml_slot, $builder->emit( 'add', 'i64', [ $mi, 1 ] ) ] );
                $builder->emit_jump($l_mloop);
                $builder->emit_label($l_mdone);
                my $is_leaf = $builder->emit( 'and', 'i64', [ $header, hex("2000000000000000") ] );
                $builder->emit_cond_br( $builder->emit( 'cmp_ne', 'Int', [ $is_leaf, 0 ] ), $l_end, $builder->new_label() );
                $builder->emit_label( $builder->last_instruction->{false_l} );

                # PROTECT STATE: Save object pointer to stack for recursion
                my $obj_slot = $driver->alloc_local_slot();
                $builder->emit( 'local_store', 'void', [ $obj_slot, $obj ] );
                my $is_arr = $builder->emit( 'and', 'i64', [ $header, hex("4000000000000000") ] );
                my $l_obj  = $builder->new_label();
                $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $is_arr, 0 ] ), $l_obj, $builder->new_label() );
                $builder->emit_label( $builder->last_instruction->{false_l} );

                # -- Array Trace --
                my $raw_count  = $builder->emit( 'load_mem_disp', 'i64', [ $obj, 0 ] );
                my $count      = $builder->emit( 'div', 'i64', [ $builder->emit( 'sub', 'i64', [ $raw_count, 1 ] ), 2 ] );
                my $count_slot = $driver->alloc_local_slot();
                $builder->emit( 'local_store', 'void', [ $count_slot, $count ] );
                my $idx_slot = $driver->alloc_local_slot();
                $builder->emit( 'local_store', 'void', [ $idx_slot, 0 ] );
                my $l_al = $builder->new_label();
                my $l_ad = $builder->new_label();
                $builder->emit_label($l_al);
                my $idx = $builder->emit( 'local_load', 'i64', [$idx_slot] );
                $builder->emit_cond_br( $builder->emit( 'cmp_ge', 'Int', [ $idx, $builder->emit( 'local_load', 'i64', [$count_slot] ) ] ),
                    $l_ad, $builder->new_label() );
                $builder->emit_label( $builder->last_instruction->{false_l} );
                my $curr_parent = $builder->emit( 'local_load', 'ptr', [$obj_slot] );
                my $el          = $builder->emit(
                    'load_mem_disp',
                    'ptr',
                    [   $builder->emit(
                            'add', 'ptr', [ $curr_parent, $builder->emit( 'add', 'i64', [ $builder->emit( 'mul', 'i64', [ $idx, 8 ] ), 8 ] ) ]
                        ),
                        0
                    ]
                );
                $builder->emit( 'call_func', 'void', [ 'M_gc_mark_obj', $el ] );
                $builder->emit( 'local_store', 'void',
                    [ $idx_slot, $builder->emit( 'add', 'i64', [ $builder->emit( 'local_load', 'i64', [$idx_slot] ), 1 ] ) ] );
                $builder->emit_jump($l_al);
                $builder->emit_label($l_ad);
                $builder->emit_jump($l_end);

                # -- Object Trace --
                $builder->emit_label($l_obj);
                my $parent_obj = $builder->emit( 'local_load',    'ptr', [$obj_slot] );
                my $vt         = $builder->emit( 'load_mem_disp', 'ptr', [ $parent_obj, 0 ] );
                my $l_no_vt    = $builder->new_label();
                $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $vt, 0 ] ), $l_no_vt, $builder->new_label() );
                $builder->emit_label( $builder->last_instruction->{false_l} );
                my $p_count      = $builder->emit( 'load_mem_disp', 'i64', [ $vt, -8 ] );
                my $p_count_slot = $driver->alloc_local_slot();
                $builder->emit( 'local_store', 'void', [ $p_count_slot, $p_count ] );
                my $p_idx_slot = $driver->alloc_local_slot();
                $builder->emit( 'local_store', 'void', [ $p_idx_slot, 0 ] );
                my $l_ol = $builder->new_label();
                my $l_od = $builder->new_label();
                $builder->emit_label($l_ol);
                my $pi = $builder->emit( 'local_load', 'i64', [$p_idx_slot] );
                $builder->emit_cond_br( $builder->emit( 'cmp_ge', 'Int', [ $pi, $builder->emit( 'local_load', 'i64', [$p_count_slot] ) ] ),
                    $l_od, $builder->new_label() );
                $builder->emit_label( $builder->last_instruction->{false_l} );
                my $f_off = $builder->emit(
                    'load_mem_disp',
                    'i64',
                    [   $builder->emit( 'sub', 'ptr', [ $vt, $builder->emit( 'add', 'i64', [ $builder->emit( 'mul', 'i64', [ $pi, 8 ] ), 16 ] ) ] ),
                        0
                    ]
                );
                my $curr_obj = $builder->emit( 'local_load',    'ptr', [$obj_slot] );
                my $child    = $builder->emit( 'load_mem_disp', 'ptr', [ $builder->emit( 'add', 'ptr', [ $curr_obj, $f_off ] ), 0 ] );
                $builder->emit( 'call_func', 'void', [ 'M_gc_mark_obj', $child ] );
                $builder->emit( 'local_store', 'void',
                    [ $p_idx_slot, $builder->emit( 'add', 'i64', [ $builder->emit( 'local_load', 'i64', [$p_idx_slot] ), 1 ] ) ] );
                $builder->emit_jump($l_ol);
                $builder->emit_label($l_od);
                $builder->emit_label($l_no_vt);
                $builder->emit_label($l_end);
                $builder->emit( 'leave_func', 'void', [0] );
            }

            # --- [2] GC Sweep (Reclaim Memory) ---
            {
                $driver->reset_locals();
                $builder->emit_label('M_gc_sweep');
                $builder->emit( 'enter_func', 'void', [] );
                my $curr_bh  = $builder->emit( 'load_iso_disp', 'ptr', [40] );    # Current block
                my $hwm_slot = $driver->alloc_local_slot();
                $builder->emit( 'local_store', 'void', [ $hwm_slot, 8 ] );        # Default: Start of block data
                my $idx_slot = $driver->alloc_local_slot();
                $builder->emit( 'local_store', 'void', [ $idx_slot, 511 ] );      # Start from top line
                my $l_loop = $builder->new_label();
                my $l_done = $builder->new_label();
                $builder->emit_label($l_loop);
                my $idx = $builder->emit( 'local_load', 'i64', [$idx_slot] );
                $builder->emit_cond_br( $builder->emit( 'cmp_lt', 'Int', [ $idx, 8 ] ), $l_done, $builder->new_label() );
                $builder->emit_label( $builder->last_instruction->{false_l} );
                my $mark   = $builder->emit( 'load_mem_byte', 'Int', [ $curr_bh, $builder->emit( 'add', 'i64', [ $idx, 8 ] ) ] );
                my $l_next = $builder->new_label();
                $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $mark, 0 ] ), $l_next, $builder->new_label() );
                $builder->emit_label( $builder->last_instruction->{false_l} );
                # FIXED: Instead of breaking on first marked line, update HWM and continue
                # to find the actual high water mark (highest line with live data)
                $builder->emit( 'local_store', 'void', [ $hwm_slot, $builder->emit( 'add', 'i64', [ $idx, 1 ] ) ] );
                # Continue loop to find the true high water mark
                $builder->emit_label($l_next);
                $builder->emit( 'local_store', 'void', [ $idx_slot, $builder->emit( 'sub', 'i64', [ $idx, 1 ] ) ] );
                $builder->emit_jump($l_loop);
                $builder->emit_label($l_done);
                my $new_ptr = $builder->emit( 'add', 'ptr',
                    [ $curr_bh, $builder->emit( 'mul', 'i64', [ $builder->emit( 'local_load', 'i64', [$hwm_slot] ), 128 ] ) ] );
                $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('heap_ptr'), $new_ptr ] );

                # FIXED: We MUST reset heap_limit to the current block bounds to prevent walking into unmapped memory
                $builder->emit( 'store_iso_disp', 'void',
                    [ $driver->iso_offset('heap_limit'), $builder->emit( 'add', 'ptr', [ $curr_bh, 65536 ] ) ] );
                $builder->emit( 'leave_func', 'void', [0] );
            }

            # --- [3] GC Collect (Root Walking) ---
            {
                $driver->reset_locals();
                $builder->emit_label('M_gc_collect');
                $builder->emit( 'enter_func', 'void', [] );
                my $c = $builder->emit( 'load_iso_disp', 'i64', [80] );
                $builder->emit( 'store_iso_disp', 'void', [ 80, $builder->emit( 'add', 'i64', [ $c, 1 ] ) ] );
                my $bh_slot = $driver->alloc_local_slot();
                $builder->emit( 'local_store', 'void', [ $bh_slot, $builder->emit( 'load_iso_disp', 'ptr', [40] ) ] );
                my $l_c1 = $builder->new_label();
                my $l_c2 = $builder->new_label();
                $builder->emit_label($l_c1);
                my $cbh = $builder->emit( 'local_load', 'ptr', [$bh_slot] );
                $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $cbh, 0 ] ), $l_c2, $builder->new_label() );
                $builder->emit_label( $builder->last_instruction->{false_l} );

                # Clear the line bitmap (bytes 8-519 = 512 lines)
                my $bm_slot = $driver->alloc_local_slot();
                $builder->emit( 'local_store', 'void', [ $bm_slot, $builder->emit( 'constant', 'i64', [8] ) ] );
                my $l_bm_clr = $builder->new_label();
                my $l_bm_end = $builder->new_label();
                $builder->emit_label($l_bm_clr);
                my $bm_off = $builder->emit( 'local_load', 'i64', [$bm_slot] );
                $builder->emit_cond_br( $builder->emit( 'cmp_lt', 'Int', [ $bm_off, 512 ] ), $builder->new_label(), $l_bm_end );
                $builder->emit_label( $builder->last_instruction->{true_l} );
                $builder->emit( 'store_mem_byte', 'void', [ $cbh, $bm_off, 0 ] );
                $builder->emit( 'local_store', 'void', [ $bm_slot, $builder->emit( 'add', 'i64', [ $bm_off, 1 ] ) ] );
                $builder->emit_jump($l_bm_clr);
                $builder->emit_label($l_bm_end);

                # Clear the header root slots (offsets 8-511, stepping by 8)
                for ( my $off = 8; $off < 520; $off += 8 ) { $builder->emit( 'store_mem_disp', 'void', [ $cbh, $off, 0 ] ); }
                $builder->emit( 'local_store', 'void', [ $bh_slot, $builder->emit( 'load_mem_disp', 'ptr', [ $cbh, 0 ] ) ] );
                $builder->emit_jump($l_c1);
                $builder->emit_label($l_c2);
                my $fib_slot = $driver->alloc_local_slot();
                $builder->emit( 'local_store', 'void', [ $fib_slot, $builder->emit( 'load_iso_disp', 'ptr', [32] ) ] );
                my $l_fl = $builder->new_label();
                my $l_fd = $builder->new_label();
                $builder->emit_label($l_fl);

                # --- START FIBER TRACE ---
                my $fib = $builder->emit( 'local_load', 'ptr', [$fib_slot] );
                $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $fib, 0 ] ), $l_fd, $builder->new_label() );
                $builder->emit_label( $builder->last_instruction->{false_l} );
                $builder->emit( 'call_func', 'void', [ 'M_gc_mark_obj', $fib ] );

                # RELOAD FIBER AFTER CALL (Volatile Protection)
                $fib = $builder->emit( 'local_load', 'ptr', [$fib_slot] );
                my $ss_base = $builder->emit( 'load_mem_disp', 'ptr', [ $fib, 24 ] );
                my $ss_ptr  = $builder->emit( 'load_mem_disp', 'ptr', [ $fib, 32 ] );
                my $cs_slot = $driver->alloc_local_slot();
                $builder->emit( 'local_store', 'void', [ $cs_slot, $ss_base ] );
                my $l_sl = $builder->new_label();
                my $l_sd = $builder->new_label();
                $builder->emit_label($l_sl);
                my $ccs = $builder->emit( 'local_load', 'ptr', [$cs_slot] );

                # Check against original ss_ptr reloaded from the current fiber on the stack
                my $re_fib = $builder->emit( 'local_load',    'ptr', [$fib_slot] );
                my $limit  = $builder->emit( 'load_mem_disp', 'ptr', [ $re_fib, 32 ] );
                $builder->emit_cond_br( $builder->emit( 'cmp_ge', 'Int', [ $ccs, $limit ] ), $l_sd, $builder->new_label() );
                $builder->emit_label( $builder->last_instruction->{false_l} );
                $builder->emit( 'call_func', 'void', [ 'M_gc_mark_obj', $builder->emit( 'load_mem_disp', 'ptr', [ $ccs, 0 ] ) ] );

                # RELOAD CURSOR AFTER CALL
                $ccs = $builder->emit( 'local_load', 'ptr', [$cs_slot] );
                $builder->emit( 'local_store', 'void', [ $cs_slot, $builder->emit( 'add', 'ptr', [ $ccs, 8 ] ) ] );
                $builder->emit_jump($l_sl);
                $builder->emit_label($l_sd);

                # RELOAD FIBER ONE LAST TIME TO GET NEXT
                my $f_final = $builder->emit( 'local_load', 'ptr', [$fib_slot] );
                $builder->emit( 'local_store', 'void', [ $fib_slot, $builder->emit( 'load_mem_disp', 'ptr', [ $f_final, 48 ] ) ] );
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
                my $psz = $builder->emit( 'get_arg', 'i64', [0] );

                # Strip the tag
                my $rsz = $builder->emit( 'and', 'i64', [ $psz, $builder->emit( 'constant', 'i64', [ hex("1FFFFFFFFFFFFFFF") ] ) ] );

                # Raw size: requested size + 8 byte header
                my $sz_raw = $builder->emit( 'add', 'i64', [ $rsz, 8 ] );

                # Align allocation to 8 bytes
                my $sz_plus7       = $builder->emit( 'add',           'i64', [ $sz_raw,   7 ] );
                my $sz             = $builder->emit( 'and',           'i64', [ $sz_plus7, $builder->emit( 'constant', 'i64', [-8] ) ] );
                my $ap             = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('heap_ptr') ] );
                my $lp             = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('heap_limit') ] );
                my $ret_slot       = $driver->alloc_local_slot();
                my $l_zero_and_ret = $builder->new_label();
                my $l_f            = $builder->new_label();
                my $l_s            = $builder->new_label();
                $builder->emit_cond_br( $builder->emit( 'cmp_lt', 'Int', [ $builder->emit( 'add', 'ptr', [ $ap, $sz ] ), $lp ] ), $l_f, $l_s );
                $builder->emit_label($l_f);
                $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('heap_ptr'), $builder->emit( 'add', 'ptr', [ $ap, $sz ] ) ] );
                $builder->emit( 'store_mem_disp', 'void', [ $ap, 0, $psz ] );
                $builder->emit( 'local_store',    'void', [ $ret_slot, $ap ] );
                $builder->emit_jump($l_zero_and_ret);
                $builder->emit_label($l_s);
                $builder->emit( 'call_func', 'void', ['M_gc_collect'] );
                my $ap2  = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('heap_ptr') ] );
                my $lp2  = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('heap_limit') ] );
                my $l_f2 = $builder->new_label();
                my $l_s2 = $builder->new_label();
                $builder->emit_cond_br( $builder->emit( 'cmp_lt', 'Int', [ $builder->emit( 'add', 'ptr', [ $ap2, $sz ] ), $lp2 ] ), $l_f2, $l_s2 );
                $builder->emit_label($l_f2);
                $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('heap_ptr'), $builder->emit( 'add', 'ptr', [ $ap2, $sz ] ) ] );
                $builder->emit( 'store_mem_disp', 'void', [ $ap2, 0, $psz ] );
                $builder->emit( 'local_store',    'void', [ $ret_slot, $ap2 ] );
                $builder->emit_jump($l_zero_and_ret);
                $builder->emit_label($l_s2);
                my $raw = $builder->emit( 'intrinsic_alloc', 'ptr', [ $BLOCK_SIZE ] );
                my $fr  = $builder->emit( 'and',             'i64', [ $builder->emit( 'add', 'ptr', [ $raw, $BLOCK_SIZE - 1 ] ), -$BLOCK_SIZE ] );

                # Update heap_min
                my $curr_min  = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('heap_min') ] );
                my $l_not_min = $builder->new_label();
                $builder->emit_cond_br( $builder->emit( 'cmp_lt', 'Int', [ $fr, $curr_min ] ), $builder->new_label(), $l_not_min );
                $builder->emit_label( $builder->last_instruction->{true_l} );
                $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('heap_min'), $fr ] );
                $builder->emit_label($l_not_min);

                # Update heap_max
                my $fr_end    = $builder->emit( 'add',           'ptr', [ $fr, $BLOCK_SIZE ] );
                my $curr_max  = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('heap_max') ] );
                my $l_not_max = $builder->new_label();
                $builder->emit_cond_br( $builder->emit( 'cmp_gt', 'Int', [ $fr_end, $curr_max ] ), $builder->new_label(), $l_not_max );
                $builder->emit_label( $builder->last_instruction->{true_l} );
                $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('heap_max'), $fr_end ] );
                $builder->emit_label($l_not_max);
                my $old_head = $builder->emit( 'load_iso_disp', 'ptr', [40] );
                $builder->emit( 'store_mem_disp', 'void', [ $fr, 0, $old_head ] );
                $builder->emit( 'store_iso_disp', 'void', [ 40, $fr ] );

                # Standardize object start at 1KB offset
                my $st = $builder->emit( 'add', 'ptr', [ $fr, 1024 ] );
                $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('heap_ptr'), $builder->emit( 'add', 'ptr', [ $st, $sz ] ) ] );
                $builder->emit( 'store_iso_disp', 'void',
                    [ $driver->iso_offset('heap_limit'), $builder->emit( 'add', 'ptr', [ $fr, $BLOCK_SIZE ] ) ] );
                $builder->emit( 'store_mem_disp', 'void', [ $st, 0, $psz ] );
                $builder->emit( 'local_store', 'void', [ $ret_slot, $st ] );
                $builder->emit_jump($l_zero_and_ret);

                # The common return block
                $builder->emit_label($l_zero_and_ret);
                my $obj_hdr   = $builder->emit( 'local_load', 'ptr', [$ret_slot] );
                my $obj_start = $builder->emit( 'add',        'ptr', [ $obj_hdr, 8 ] );
                my $obj_end   = $builder->emit( 'add',        'ptr', [ $obj_hdr, $sz ] );
                my $z_ptr     = $driver->alloc_local_slot();
                $builder->emit( 'local_store', 'void', [ $z_ptr, $obj_start ] );
                my $l_zloop = $builder->new_label();
                my $l_zend  = $builder->new_label();
                $builder->emit_label($l_zloop);
                $builder->emit_cond_br( $builder->emit( 'cmp_lt', 'Int', [ $builder->emit( 'local_load', 'ptr', [$z_ptr] ), $obj_end ] ),
                    $builder->new_label(), $l_zend );
                $builder->emit_label( $builder->last_instruction->{true_l} );
                $builder->emit( 'store_mem_disp', 'void',
                    [ $builder->emit( 'local_load', 'ptr', [$z_ptr] ), 0, $builder->emit( 'constant', 'i64', [0] ) ] );
                $builder->emit( 'local_store', 'void',
                    [ $z_ptr, $builder->emit( 'add', 'ptr', [ $builder->emit( 'local_load', 'ptr', [$z_ptr] ), 8 ] ) ] );
                $builder->emit_jump($l_zloop);
                $builder->emit_label($l_zend);
                $builder->emit( 'leave_func', 'void', [$obj_start] );
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

            # ---[6] Fiber New ---
            $self->_lower_fiber_new_runtime();

            # --- [7] Concat ---
            {
                $driver->reset_locals();
                $builder->emit_label('M_concat');
                $builder->emit( 'enter_func', 'void', [] );
                my $s1  = $builder->emit( 'get_arg', 'ptr', [0] );
                my $s1s = $driver->alloc_local_slot();
                $builder->emit( 'local_store', 'void', [ $s1s, $s1 ] );
                my $s2  = $builder->emit( 'get_arg', 'ptr', [1] );
                my $s2s = $driver->alloc_local_slot();
                $builder->emit( 'local_store', 'void', [ $s2s, $s2 ] );
                my $l1  = $builder->emit( 'load_mem_disp', 'i64', [ $s1, 0 ] );
                my $l1s = $driver->alloc_local_slot();
                $builder->emit( 'local_store', 'void', [ $l1s, $l1 ] );
                my $l2  = $builder->emit( 'load_mem_disp', 'i64', [ $s2, 0 ] );
                my $l2s = $driver->alloc_local_slot();
                $builder->emit( 'local_store', 'void', [ $l2s, $l2 ] );
                my $total = $builder->emit( 'add', 'i64', [ $l1, $l2 ] );
                my $ts    = $driver->alloc_local_slot();
                $builder->emit( 'local_store', 'void', [ $ts, $total ] );
                my $tag        = $builder->emit( 'constant',  'i64', [ hex("2000000000000000") ] );
                my $hdr        = $builder->emit( 'constant',  'i64', [16] );
                my $alloc_size = $builder->emit( 'add',       'i64', [ $total,      $hdr ] );
                my $tagged     = $builder->emit( 'or',        'i64', [ $alloc_size, $tag ] );
                my $new        = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', $tagged ] );
                my $ns         = $driver->alloc_local_slot();
                $builder->emit( 'local_store', 'void', [ $ns, $new ] );
                $builder->emit( 'store_mem_disp', 'void', [ $new, 0, $total ] );
                my $cl1  = $builder->new_label();
                my $cl1b = $builder->new_label();
                my $cl1d = $builder->new_label();
                my $is   = $driver->alloc_local_slot();
                $builder->emit( 'local_store', 'void', [ $is, $builder->emit( 'constant', 'i64', [0] ) ] );
                $builder->emit_label($cl1);
                my $ci   = $builder->emit( 'local_load', 'i64', [$is] );
                my $cl1v = $builder->emit( 'local_load', 'i64', [$l1s] );
                $builder->emit_cond_br( $builder->emit( 'cmp_lt', 'Int', [ $ci, $cl1v ] ), $cl1b, $cl1d );
                $builder->emit_label($cl1b);
                my $cs1 = $builder->emit( 'local_load',    'ptr', [$s1s] );
                my $co1 = $builder->emit( 'add',           'i64', [ $builder->emit( 'local_load', 'i64', [$is] ), 16 ] );
                my $cb  = $builder->emit( 'load_mem_byte', 'Int', [ $cs1, $co1 ] );
                $builder->emit( 'store_mem_byte', 'void', [ $builder->emit( 'local_load', 'ptr', [$ns] ), $co1, $cb ] );
                $builder->emit( 'local_store', 'void', [ $is, $builder->emit( 'add', 'i64', [ $builder->emit( 'local_load', 'i64', [$is] ), 1 ] ) ] );
                $builder->emit_jump($cl1);
                $builder->emit_label($cl1d);
                my $cl2  = $builder->new_label();
                my $cl2b = $builder->new_label();
                my $cl2d = $builder->new_label();
                my $js   = $driver->alloc_local_slot();
                $builder->emit( 'local_store', 'void', [ $js, $builder->emit( 'constant', 'i64', [0] ) ] );
                $builder->emit_label($cl2);
                my $cj   = $builder->emit( 'local_load', 'i64', [$js] );
                my $cl2v = $builder->emit( 'local_load', 'i64', [$l2s] );
                $builder->emit_cond_br( $builder->emit( 'cmp_lt', 'Int', [ $cj, $cl2v ] ), $cl2b, $cl2d );
                $builder->emit_label($cl2b);
                my $cs2 = $builder->emit( 'local_load',    'ptr', [$s2s] );
                my $co2 = $builder->emit( 'add',           'i64', [ $builder->emit( 'local_load', 'i64', [$js] ), 16 ] );
                my $cb2 = $builder->emit( 'load_mem_byte', 'Int', [ $cs2, $co2 ] );
                my $dl  = $builder->emit( 'add',           'i64', [ $co2, $builder->emit( 'local_load', 'i64', [$l1s] ) ] );
                $builder->emit( 'store_mem_byte', 'void', [ $builder->emit( 'local_load', 'ptr', [$ns] ), $dl, $cb2 ] );
                $builder->emit( 'local_store', 'void', [ $js, $builder->emit( 'add', 'i64', [ $builder->emit( 'local_load', 'i64', [$js] ), 1 ] ) ] );
                $builder->emit_jump($cl2);
                $builder->emit_label($cl2d);
                $builder->emit( 'leave_func', 'void', [ $builder->emit( 'local_load', 'ptr', [$ns] ) ] );
            }

            # --- [8] Any to String ---
            {
                $driver->reset_locals();
                $builder->emit_label('M_any_to_str');
                $builder->emit( 'enter_func', 'void', [] );
                my $v      = $builder->emit( 'get_arg', 'i64', [0] );
                my $is_int = $builder->emit( 'and',     'i64', [ $v, 1 ] );
                my $l_str  = $builder->new_label();
                my $l_int  = $builder->new_label();
                $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $is_int, 0 ] ), $l_str, $l_int );
                $builder->emit_label($l_str);
                $builder->emit( 'leave_func', 'void', [$v] );
                $builder->emit_label($l_int);
                my $n    = $builder->emit( 'div', 'i64', [ $builder->emit( 'sub', 'i64', [ $v, 1 ] ), 2 ] );
                my $l_z  = $builder->new_label();
                my $l_nz = $builder->new_label();
                $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $n, 0 ] ), $l_z, $l_nz );
                $builder->emit_label($l_z);
                $builder->emit( 'leave_func', 'void', [ $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string("0") ] ) ] );
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
                my $len        = $builder->emit( 'local_load', 'i64', [$is] );
                my $hdr        = $builder->emit( 'constant',   'i64', [16] );
                my $data_size  = $builder->emit( 'add',        'i64', [ $len, $hdr ] );
                my $tag        = $builder->emit( 'constant',   'i64', [ hex("2000000000000000") ] );
                my $alloc_size = $builder->emit( 'or',         'i64', [ $data_size, $tag ] );
                my $new_str    = $builder->emit( 'call_func',  'ptr', [ 'M_gc_alloc', $alloc_size ] );
                my $ns_slot    = $driver->alloc_local_slot();
                $builder->emit( 'local_store', 'void', [ $ns_slot, $new_str ] );
                $builder->emit( 'store_mem_disp', 'void', [ $new_str, 0, $len ] );
                my $ds = $driver->alloc_local_slot();
                $builder->emit( 'local_store', 'void', [ $ds, $builder->emit( 'constant', 'i64', [0] ) ] );
                my $l3 = $builder->new_label();
                my $l4 = $builder->new_label();
                $builder->emit_label($l3);
                my $ci = $builder->emit( 'sub', 'i64', [ $builder->emit( 'local_load', 'i64', [$is] ), 1 ] );
                $builder->emit( 'local_store', 'void', [ $is, $ci ] );
                my $di = $builder->emit( 'local_load', 'i64', [$ds] );
                $builder->emit(
                    'store_mem_byte',
                    'void',
                    [   $builder->emit( 'local_load',    'ptr', [$ns_slot] ),
                        $builder->emit( 'add',           'i64', [ $di,                                          16 ] ),
                        $builder->emit( 'load_mem_byte', 'Int', [ $builder->emit( 'local_load', 'ptr', [$bs] ), $ci ] )
                    ]
                );
                $builder->emit( 'local_store', 'void', [ $ds, $builder->emit( 'add', 'i64', [ $di, 1 ] ) ] );
                $builder->emit_cond_br( $builder->emit( 'cmp_gt', 'Int', [ $ci, 0 ] ), $l3, $l4 );
                $builder->emit_label($l4);
                $builder->emit( 'leave_func', 'void', [ $builder->emit( 'local_load', 'ptr', [$ns_slot] ) ] );
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
            my $saved_fn = $current_func_name;
            my ( $vr, $vt ) = $self->lower( $node->value );
            my $sl = $driver->alloc_local_slot();
            $current_scope->define( $node->name, $node->type eq 'Any' ? $vt : $node->type, 0, undef, $sl );
            $builder->emit( 'local_store', 'void', [ $sl, $vr ] );
            $current_func_name = $saved_fn;
            $self->_collect_local( $node->name, $node->type eq 'Any' ? $vt : $node->type, $sl );
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
            if ( $node->op eq '&&' || $node->op eq '||' || $node->op eq '//' ) { return $self->_lower_logical($node); }
            my ( $lr, $lt ) = $self->lower( $node->left );
            my ( $rr, $rt ) = $self->lower( $node->right );
            if ( $node->op eq '.' ) {
                my $lc = $lt eq 'String' ? $lr : $builder->emit( 'call_func', 'ptr', [ 'M_any_to_str', $lr ] );
                my $rc = $rt eq 'String' ? $rr : $builder->emit( 'call_func', 'ptr', [ 'M_any_to_str', $rr ] );
                return ( $builder->emit( 'call_func', 'ptr', [ 'M_concat', $lc, $rc ] ), 'String' );
            }
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
            my $entry_height = scalar @defer_stack;                       # Track stack height on entry
            my @res          = $self->lower_block( $node->statements );
            while ( scalar @defer_stack > $entry_height ) {               # Pop and emit only what was added in this block
                my $fragment = pop @defer_stack;
                for my $inst (@$fragment) {
                    $builder->push_instruction($inst);
                }
            }
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
            if ( $node->name eq 'sleep' ) {
                my ( $r, $t ) = $self->lower( $node->args->[0] // Brocken::AST::Expr::Const->new( value => 1, type => 'Int' ) );

                # We emit an intrinsic so the platform handles the specific units (ms vs ns)
                $builder->emit( 'intrinsic_sleep', 'void', [$r] );
                return ( undef, 'void' );
            }

            # --- OPEN ---
            if ( $node->name eq 'open' ) {
                my $path_node  = $node->args->[0] // die "open requires a path";
                my $mode_node  = $node->args->[1] // Brocken::AST::Expr::Const->new( value => "r", type => 'String' );
                my ($path_reg) = $self->lower($path_node);
                my ($mode_reg) = $self->lower($mode_node);
                my $fd         = $builder->emit( 'intrinsic_open', 'i64', [ $path_reg, $mode_reg ] );

                # Wrap raw FD in a FileHandle object
                my $obj = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', $builder->emit( 'constant', 'i64', [32] ) ] );
                $builder->emit( 'store_mem_disp', 'void', [ $obj, 8, $fd ] );
                return ( $obj, 'FileHandle' );
            }

            # --- CLOSE ---
            if ( $node->name eq 'close' ) {
                my ( $fh, $ft ) = $self->lower( $node->args->[0] );
                my $fd = $builder->emit( 'load_mem_disp', 'i64', [ $fh, 8 ] );
                $builder->emit( 'intrinsic_close', 'void', [$fd] );
                return ( undef, 'void' );
            }

            # --- SLURP ---
            if ( $node->name eq 'slurp' ) {
                my ($path_reg) = $self->lower( $node->args->[0] );
                my $mode_ptr   = $builder->emit( 'load_data_addr',     'ptr', [ $data_segment->add_string("r") ] );
                my $fd         = $builder->emit( 'intrinsic_open',     'i64', [ $path_reg, $mode_ptr ] );
                my $size       = $builder->emit( 'intrinsic_get_size', 'i64', [$fd] );
                my $tag        = $builder->emit( 'constant',           'i64', [ hex("2000000000000000") ] );
                my $alloc_size = $builder->emit( 'or',                 'i64', [ $builder->emit( 'add', 'i64', [ $size, 16 ] ), $tag ] );
                my $str_obj    = $builder->emit( 'call_func',          'ptr', [ 'M_gc_alloc', $alloc_size ] );
                $builder->emit( 'store_mem_disp', 'void', [ $str_obj, 0, $size ] );
                my $data_ptr = $builder->emit( 'add', 'ptr', [ $str_obj, 16 ] );
                $builder->emit( 'intrinsic_read', 'i64', [ $fd, $data_ptr, $size ] );
                $builder->emit( 'intrinsic_close', 'void', [$fd] );
                return ( $str_obj, 'String' );
            }
            if ( $node->name eq 'print' ) {
                if ( scalar @{ $node->args } > 1 ) {

                    # print $fh, $val
                    my ($fh_reg) = $self->lower( $node->args->[0] );
                    my ( $val_reg, $val_type ) = $self->lower( $node->args->[1] );
                    my $fd = $builder->emit( 'load_mem_disp', 'i64', [ $fh_reg, 8 ] );
                    if ( $val_type eq 'String' ) {
                        my $len = $builder->emit( 'load_mem_disp', 'i64', [ $val_reg, 0 ] );
                        my $ptr = $builder->emit( 'add',           'ptr', [ $val_reg, 16 ] );
                        $builder->emit( 'intrinsic_write', 'void', [ $fd, $ptr, $len ] );
                    }
                    else {
                        # For Int/Any, you'd call a conversion helper here
                        my $str = $builder->emit( 'call_func',     'ptr', [ 'M_any_to_str', $val_reg ] );
                        my $len = $builder->emit( 'load_mem_disp', 'i64', [ $str, 0 ] );
                        my $ptr = $builder->emit( 'add',           'ptr', [ $str, 16 ] );
                        $builder->emit( 'intrinsic_write', 'void', [ $fd, $ptr, $len ] );
                    }
                }
                else {
                    # Standard print to STDOUT
                    my ( $r, $t ) = $self->lower( $node->args->[0] );
                    if   ( $t eq 'String' ) { $builder->emit( 'intrinsic_print', 'void', [$r] ); }
                    else                    { $builder->emit( 'call_func',       'void', [ 'M_print_any', $r ] ); }
                }
                return ( undef, 'void' );
            }
            if ( $node->name eq 'say' ) {
                my ( $r, $t ) = $self->lower( $node->args->[0] );
                if    ( $t eq 'String' ) { $builder->emit( 'intrinsic_print', 'void', [$r] ); }
                elsif ( $t eq 'Int' )    { $builder->emit( 'call_func',       'void', [ 'M_print_int', $r ] ); }
                else                     { $builder->emit( 'call_func',       'void', [ 'M_print_any', $r ] ); }
                if ( $node->name eq 'say' ) {
                    $builder->emit( 'intrinsic_print', 'void', [ $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string("\n") ] ) ] );
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
            $builder->set_instructions();    # Clear temporarily
            $defer_active_depth++;
            $self->lower( $node->block );
            $defer_active_depth--;
            my @deferred_instructions = $builder->instructions;
            $builder->set_instructions(@saved_instructions);    # Restore
            push @defer_stack, \@deferred_instructions;
            return ( undef, 'void' );
        }

        method lower_Return($node) {
            die "Semantic Error: 'return' is not allowed inside a defer block. Use logic flow to exit the block early if needed.\n"
                if $defer_active_depth > 0;
            die "Return outside sub\n" if $routine_depth == 0;
            my ( $rv, $ty );
            if ( defined $node->expr ) {
                ( $rv, $ty ) = $self->lower( $node->expr );
            }
            else {
                $rv = $builder->emit( 'constant', 'i64', [1] );
                $ty = 'Int';
            }
            $self->_emit_all_defers();    # Run all defers back to function start
            if ( $routine_types[-1] eq 'fiber' ) {
                my $fcb = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('current_fcb') ] );
                $builder->emit( 'call_func', 'Any',
                    [ 'M_fiber_switch', $builder->emit( 'load_mem_disp', 'ptr', [ $fcb, $driver->fcb_offset('caller') ] ), $rv ] );
                $builder->emit( 'intrinsic_exit', 'void', [0] );
            }
            else { $builder->emit( 'leave_func', 'void', [$rv] ); }
            return ( undef, 'void' );
        }

        method lower_Exit($node) {
            my $ev;
            if ( defined $node->expr ) {
                ($ev) = $self->lower( $node->expr );
            }
            else {
                $ev = $builder->emit( 'constant', 'i64', [1] );    # Exit code 0
            }
            $self->_emit_all_defers();
            $builder->emit( 'intrinsic_exit', 'void', [$ev] );
            return ( undef, 'void' );
        }

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
                my @old_defers = @defer_stack;
                @defer_stack = ();
                my $func_name = 'M_' . $node->name . '::' . $m->name;
                $builder->emit_label($func_name);
                $builder->emit( 'enter_func', 'void', [] );
                $current_scope = Brocken::Scope->new( parent => $current_scope );
                $routine_depth++;
                $current_func_name = $func_name;
                @func_locals       = ();
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
                if ( $driver->debug >= 2 ) {
                    my @params = ( { name => '$self', type => 'ptr', slot => $ss } );
                    for my $p ( @{ $m->params } ) {
                        my $sym = $current_scope->resolve( $p->{name} );
                        push @params, { name => $p->{name}, type => $p->{type}, slot => $sym->stack_offset };
                    }
                    $driver->set_debug_func_params( $func_name, \@params );
                }
                $self->lower_block( $m->body->statements );
                $self->_emit_all_defers();
                $self->_flush_func_locals();
                $builder->emit( 'leave_func', 'void', [0] );
                $routine_depth--;
                $current_scope = $current_scope->parent;
                @defer_stack   = @old_defers;
            }
            pop @routine_types;
            return ( undef, 'void' );
        }

        method lower_Method($node) {
            push @routine_types, 'method';
            my @old_defers = @defer_stack;
            @defer_stack = ();
            $driver->reset_locals();
            my $func_name = 'M_' . $node->name;
            $builder->emit_label($func_name);
            $builder->emit( 'enter_func', 'void', [] );
            $current_scope = Brocken::Scope->new( parent => $current_scope );
            $routine_depth++;
            $current_func_name = $func_name;
            @func_locals       = ();
            my $ai = 0;

            for my $p ( @{ $node->params } ) {
                my $sl = $driver->alloc_local_slot();
                $current_scope->define( $p->{name}, $p->{type}, 0, undef, $sl );
                $builder->emit( 'local_store', 'void', [ $sl, $builder->emit( 'get_arg', 'i64', [ $ai++ ] ) ] );
            }
            if ( $driver->debug >= 2 ) {
                my @params;
                for my $p ( @{ $node->params } ) {
                    my $sym = $current_scope->resolve( $p->{name} );
                    push @params, { name => $p->{name}, type => $p->{type}, slot => $sym->stack_offset };
                }
                $driver->set_debug_func_params( $func_name, \@params );
            }
            $self->lower_block( $node->body->statements );
            $self->_emit_all_defers();
            $self->_flush_func_locals();
            $builder->emit( 'leave_func', 'void', [0] );
            $routine_depth--;
            $current_scope = $current_scope->parent;
            @defer_stack   = @old_defers;
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
            my @as = map { ( $self->lower($_) )[0] } @{ $node->args };
            if ( $ot eq 'Fiber' && $node->name eq 'switch' ) {
                return ( $builder->emit( 'call_func', 'Any', [ 'M_fiber_switch', $or, @as ] ), 'Any' );
            }
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
            my @old_defers = @defer_stack;
            @defer_stack = ();
            my $saved_func_name   = $current_func_name;
            my @saved_func_locals = @func_locals;
            $builder->emit_label($l1);
            $builder->emit( 'enter_func', 'void', [] );
            $current_scope = Brocken::Scope->new( parent => $current_scope );
            $routine_depth++;
            $current_func_name = $l1;
            @func_locals       = ();
            push @routine_types, 'fiber';

            if ( scalar @{ $node->params } > 0 ) {
                my $sl = $driver->alloc_local_slot();
                $current_scope->define( $node->params->[0]{name}, $node->params->[0]{type}, 0, undef, $sl );
                $builder->emit( 'local_store', 'void', [ $sl, $builder->emit( 'mov', 'Any', [ ( $driver->arch eq 'x64' ? 'rax' : 'x0' ) ] ) ] );
                if ( $driver->debug >= 2 ) {
                    my $sym = $current_scope->resolve( $node->params->[0]{name} );
                    $driver->set_debug_func_params( $l1,
                        [ { name => $node->params->[0]{name}, type => $node->params->[0]{type}, slot => $sym->stack_offset } ] );
                }
            }
            my ( $res, $ty ) = $self->lower_block( $node->body->statements );
            $self->_emit_all_defers();
            my $fcb = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('current_fcb') ] );
            $builder->emit( 'call_func', 'Any',
                [ 'M_fiber_switch', $builder->emit( 'load_mem_disp', 'ptr', [ $fcb, $driver->fcb_offset('caller') ] ), $res // 3 ] );
            $builder->emit( 'intrinsic_exit', 'void', [0] );
            $self->_flush_func_locals();
            pop @routine_types;
            $routine_depth--;
            $current_scope     = $current_scope->parent;
            @defer_stack       = @old_defers;              # Restore caller's defers
            $current_func_name = $saved_func_name;
            @func_locals       = @saved_func_locals;
            my @ir = $builder->instructions;
            $builder->set_instructions( @saved, @ir );
            $builder->emit_label($l2);
            $driver->set_local_ptr($op);
            return ( $builder->emit( 'call_func', 'ptr', [ 'M_fiber_new', $l1 ] ), 'Fiber' );
        }

        method lower_Yield($node) {
            my $yv;
            if ( defined $node->expr ) {
                ($yv) = $self->lower( $node->expr );
            }
            else {
                $yv = $builder->emit( 'constant', 'i64', [1] );    # Yield 0
            }
            my $fcb = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('current_fcb') ] );
            return (
                $builder->emit(
                    'call_func', 'Int', [ 'M_fiber_switch', $builder->emit( 'load_mem_disp', 'ptr', [ $fcb, $driver->fcb_offset('caller') ] ), $yv ]
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
                    my @old_defers = @defer_stack;
                    @defer_stack = ();
                    $builder->emit_label($lb);
                    $builder->emit( 'enter_func', 'void', [] );
                    $current_scope = Brocken::Scope->new( parent => $current_scope );
                    $routine_depth++;
                    $current_func_name = $lb;
                    @func_locals       = ();
                    my $ai = 0;

                    for my $p ( @{ $node->params } ) {
                        my $sl = $driver->alloc_local_slot();
                        $current_scope->define( $p->{name}, $p->{type}, 0, undef, $sl );
                        $builder->emit( 'local_store', 'void', [ $sl, $builder->emit( 'get_arg', 'i64', [ $ai++ ] ) ] );
                    }
                    if ( $driver->debug >= 2 ) {
                        my @params;
                        for my $p ( @{ $node->params } ) {
                            my $sym = $current_scope->resolve( $p->{name} );
                            push @params, { name => $p->{name}, type => $p->{type}, slot => $sym->stack_offset };
                        }
                        $driver->set_debug_func_params( $lb, \@params );
                    }
                    $self->lower_block( $node->body->statements );
                    $self->_emit_all_defers();
                    $self->_flush_func_locals();
                    $builder->emit( 'leave_func', 'void', [0] );
                    $routine_depth--;
                    $current_scope = $current_scope->parent;
                    @defer_stack   = @old_defers;
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
