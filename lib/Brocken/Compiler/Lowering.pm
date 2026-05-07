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

        # --- Core Dispatcher ---
        method lower($node) {
            return ( undef, 'void' ) unless defined $node;

            # Get the class name without the package prefix
            my $node_type = ref($node);
            $node_type =~ s/.*:://;
            my $method = "lower_$node_type";
            if ( $self->can($method) ) {
                return $self->$method($node);
            }
            die "Lowering Error: No handler implemented for AST node type '$node_type'";
        }

        method lower_block($statements) {
            my ( $reg, $type );
            for my $stmt (@$statements) { ( $reg, $type ) = $self->lower($stmt); }
            return ( $reg, $type );
        }

        method lower_program($nodes) {

            # 1. Initial setup: Jump to entry, inject internal runtime subs
            $builder->emit_jump('L_MAIN_START');
            $self->inject_runtime();
            $self->register_classes($nodes);

            # 2. Separate global definitions (subs/classes) from mainline logic
            my @main_stmts;
            for my $node (@$nodes) {
                if    ( $node isa Brocken::AST::Method )    { $self->lower($node); }
                elsif ( $node isa Brocken::AST::ClassDecl ) { $self->lower($node); }
                else                                        { push @main_stmts, $node; }
            }

            # 3. Emit Main Entry Point
            $driver->reset_locals();
            $builder->emit_label('L_MAIN_START');
            $builder->emit( 'enter_func', 'void', [] );

            # OS-specific setup
            $builder->emit( 'setup_page_fault_handler', 'void', [] );
            $builder->emit( 'setup_console',            'void', [] );

            # 4. Initialize Isolate Context
            my $iso_reg      = $builder->emit( 'sys_alloc', 'ptr', [1024] );
            my $iso_reg_slot = $driver->alloc_local_slot();
            $builder->emit( 'local_store',     'void', [ $iso_reg_slot, $iso_reg ] );
            $builder->emit( 'set_isolate_ctx', 'void', [$iso_reg] );

            # Initialize Fiber Head
            $builder->emit( 'store_mem_disp', 'void', [ $iso_reg, $driver->iso_offset('fiber_head'), $builder->emit( 'constant', 'i64', [0] ) ] );

            # 5. Initialize Heap (256MB)
            my $c1m       = $builder->emit( 'constant',  'i64', [268435456] );
            my $init_heap = $builder->emit( 'sys_alloc', 'ptr', [$c1m] );
            $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('heap_ptr'),   $init_heap ] );
            $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('heap_limit'), $builder->emit( 'add', 'ptr', [ $init_heap, $c1m ] ) ] );

            # 6. Initialize State/VTable Memory
            my $state_mem = $builder->emit( 'sys_alloc', 'ptr', [1048576] );
            $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('state_ptr'), $state_mem ] );

            # Populate VTables for all registered classes
            for my $cname ( sort keys %class_info ) {
                my $c      = $class_info{$cname};
                my $vt_ptr = ( $global_method_count > 0 ) ? $builder->emit( 'sys_alloc', 'ptr', [ $global_method_count * 8 ] ) :
                    $builder->emit( 'constant', 'i64', [0] );
                if ( $global_method_count > 0 ) {
                    for my $mname ( @{ $c->{method_names} } ) {
                        my $gidx  = $global_methods{$mname};
                        my $f_ptr = $builder->emit( 'load_func_addr', 'ptr', ["M_${cname}::${mname}"] );
                        $builder->emit( 'store_mem_disp', 'void', [ $vt_ptr, $gidx * 8, $f_ptr ] );
                    }
                }
                $builder->emit( 'store_mem_disp', 'void', [ $state_mem, $c->{id} * 8, $vt_ptr ] );
            }

            # 7. Initialize "Main" Fiber (the mainline itself is a fiber)
            my $main_fcb  = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', 64 ] );
            my $main_shad = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', 65536 ] );
            $builder->emit( 'store_mem_disp', 'void', [ $main_fcb, $driver->fcb_offset('shadow_base'), $main_shad ] );
            $builder->emit( 'store_mem_disp', 'void', [ $main_fcb, $driver->fcb_offset('shadow_ptr'),  $main_shad ] );
            $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('current_fcb'), $main_fcb ] );
            $builder->emit( 'store_mem_disp', 'void', [ $main_fcb, $driver->fcb_offset('caller'), $builder->emit( 'constant', 'i64', [0] ) ] );
            my $iso_reg2 = $builder->emit( 'get_isolate_ctx', 'ptr', [] );
            $builder->emit( 'store_mem_disp', 'void', [ $iso_reg2, $driver->iso_offset('fiber_head'), $main_fcb ] );

            # 8. Run Mainline Logic
            $self->lower_block( \@main_stmts );

            # 9. Clean Exit
            $builder->emit( 'exit_program', 'void', [0] );

            # Append any captured fragments (anon subs, etc)
            while (@fragments) {
                my $frag = shift @fragments;
                $builder->push_instructin($_) for @$frag;
            }

            # Emit native fault handlers
            $builder->emit( 'emit_native_handlers', 'void', [] );
        }

        method register_classes($nodes) {
            for my $node (@$nodes) {
                if ( $node isa Brocken::AST::ClassDecl ) {
                    my $id = $class_id_counter++;
                    my @method_names;
                    for my $m ( @{ $node->methods } ) {
                        push @method_names, $m->name;
                        if ( !exists $global_methods{ $m->name } ) {
                            $global_methods{ $m->name } = $global_method_count++;
                        }
                    }
                    $class_info{ $node->name } = { id => $id, method_names => \@method_names, fields => $node->fields };
                }
            }
        }

        method inject_runtime() {

            # --- [1] GC Marking Logic ---
            {
                $driver->reset_locals();
                $builder->emit_label('M_gc_mark_obj');
                $builder->emit( 'enter_func', 'void', [] );
                my $obj_ptr    = $builder->emit( 'get_arg', 'ptr', [0] );
                my $l_null     = $builder->new_label();
                my $l_not_null = $builder->new_label();
                $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $obj_ptr, 0 ] ), $l_null, $l_not_null );
                $builder->emit_label($l_not_null);
                my $header    = $builder->emit( 'load_mem_disp', 'i64', [ $obj_ptr, -8 ] );
                my $mark_mask = $builder->emit( 'constant',      'i64', [0x8000000000000000] );
                my $is_marked = $builder->emit( 'and',           'i64', [ $header, $mark_mask ] );
                my $l_recurse = $builder->new_label();
                $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $is_marked, 0 ] ), $l_recurse, $l_null );
                $builder->emit_label($l_recurse);
                my $new_header = $builder->emit( 'or', 'i64', [ $header, $mark_mask ] );
                $builder->emit( 'store_mem_disp', 'void', [ $obj_ptr, -8, $new_header ] );
                my $arr_count    = $builder->emit( 'load_mem_disp', 'i64', [ $obj_ptr, 8 ] );
                my $arr_idx      = $builder->emit( 'constant', 'i64', [0] );
                my $l_loop_start = $builder->new_label();
                my $l_loop_end   = $builder->new_label();
                my $l_loop_body  = $builder->new_label();
                $builder->emit_label($l_loop_start);
                $builder->emit_cond_br( $builder->emit( 'cmp_lt', 'Int', [ $arr_idx, $arr_count ] ), $l_loop_body, $l_loop_end );
                $builder->emit_label($l_loop_body);
                my $el_off = $builder->emit( 'add', 'i64', [ 16, $builder->emit( 'mul', 'i64', [ $arr_idx, 8 ] ) ] );
                $builder->emit( 'call_func', 'void',
                    [ 'M_gc_mark_obj', $builder->emit( 'load_mem_disp', 'ptr', [ $builder->emit( 'add', 'ptr', [ $obj_ptr, $el_off ] ), 0 ] ) ] );
                $arr_idx = $builder->emit( 'add', 'i64', [ $arr_idx, 1 ] );
                $builder->emit_jump($l_loop_start);
                $builder->emit_label($l_loop_end);
                $builder->emit_label($l_null);
                $builder->emit( 'leave_func', 'void', [0] );
            }

            # --- [2] GC Sweep Logic ---
            {
                $builder->emit_label('M_gc_sweep');
                $builder->emit( 'enter_func', 'void', [] );
                my $limit_reg = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('heap_limit') ] );
                $builder->emit(
                    'store_iso_disp',
                    'void',
                    [   $driver->iso_offset('heap_ptr'),
                        $builder->emit( 'sub', 'ptr', [ $limit_reg, $builder->emit( 'constant', 'i64', [1048576] ) ] )
                    ]
                );
                $builder->emit( 'leave_func', 'void', [0] );
            }

            # --- [3] GC Collection Entry ---
            {
                $builder->emit_label('M_gc_collect');
                $builder->emit( 'enter_func', 'void', [] );
                my $fib_head   = $builder->emit( 'load_iso_disp', 'ptr', [32] );
                my $l_fib_loop = $builder->new_label();
                my $l_fib_end  = $builder->new_label();
                my $l_fib_body = $builder->new_label();
                $builder->emit_label($l_fib_loop);
                $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $fib_head, 0 ] ), $l_fib_end, $l_fib_body );
                $builder->emit_label($l_fib_body);
                my $shad_base   = $builder->emit( 'load_mem_disp', 'ptr', [ $fib_head, 16 ] );
                my $shad_ptr    = $builder->emit( 'load_mem_disp', 'ptr', [ $fib_head, 24 ] );
                my $l_shad_loop = $builder->new_label();
                my $l_shad_end  = $builder->new_label();
                my $l_shad_body = $builder->new_label();
                $builder->emit_label($l_shad_loop);
                $builder->emit_cond_br( $builder->emit( 'cmp_ge', 'Int', [ $shad_base, $shad_ptr ] ), $l_shad_end, $l_shad_body );
                $builder->emit_label($l_shad_body);
                $builder->emit( 'call_func', 'void', [ 'M_gc_mark_obj', $builder->emit( 'load_mem_disp', 'ptr', [ $shad_base, 0 ] ) ] );
                $shad_base = $builder->emit( 'add', 'ptr', [ $shad_base, 8 ] );
                $builder->emit_jump($l_shad_loop);
                $builder->emit_label($l_shad_end);
                $fib_head = $builder->emit( 'load_mem_disp', 'ptr', [ $fib_head, 40 ] );
                $builder->emit_jump($l_fib_loop);
                $builder->emit_label($l_fib_end);
                $builder->emit( 'call_func',  'void', ['M_gc_sweep'] );
                $builder->emit( 'leave_func', 'void', [0] );
            }

            # --- [4] The Memory Allocator ---
            {
                $driver->reset_locals();
                $builder->emit_label('M_gc_alloc');
                $builder->emit( 'enter_func', 'void', [] );
                my $payload_sz = $builder->emit( 'get_arg',       'i64', [0] );
                my $size       = $builder->emit( 'add',           'i64', [ $payload_sz, 8 ] );
                my $alloc_ptr  = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('heap_ptr') ] );
                my $limit_ptr  = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('heap_limit') ] );
                my $new_alloc  = $builder->emit( 'add',           'ptr', [ $alloc_ptr, $size ] );
                my $l_fast     = $builder->new_label();
                my $l_slow     = $builder->new_label();
                $builder->emit_cond_br( $builder->emit( 'cmp_lt', 'Int', [ $new_alloc, $limit_ptr ] ), $l_fast, $l_slow );
                $builder->emit_label($l_fast);
                $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('heap_ptr'), $new_alloc ] );
                $builder->emit( 'store_mem_disp', 'void', [ $alloc_ptr, 0, $payload_sz ] );
                $builder->emit( 'leave_func',     'void', [ $builder->emit( 'add', 'ptr', [ $alloc_ptr, 8 ] ) ] );
                $builder->emit_label($l_slow);
                $builder->emit( 'call_func', 'void', ['M_gc_collect'] );
                my $total_req  = $builder->emit( 'add',       'i64', [ $size, $builder->emit( 'constant', 'i64', [1048576] ) ] );
                my $new_region = $builder->emit( 'sys_alloc', 'ptr', [$total_req] );
                $builder->emit( 'store_iso_disp', 'void',
                    [ $driver->iso_offset('heap_ptr'), $builder->emit( 'add', 'ptr', [ $new_region, $size ] ) ] );
                $builder->emit( 'store_iso_disp', 'void',
                    [ $driver->iso_offset('heap_limit'), $builder->emit( 'add', 'ptr', [ $new_region, $total_req ] ) ] );
                $builder->emit( 'store_mem_disp', 'void', [ $new_region, 0, $payload_sz ] );
                $builder->emit( 'leave_func',     'void', [ $builder->emit( 'add', 'ptr', [ $new_region, 8 ] ) ] );
            }

            # --- [5] Integer Printer ---
            {
                $driver->reset_locals();
                $builder->emit_label('M_print_int');
                $builder->emit( 'enter_func', 'void', [] );
                my $n       = $builder->emit( 'get_arg', 'i64', [0] );
                my $l_z     = $builder->new_label();
                my $l_not_z = $builder->new_label();
                $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $n, 0 ] ), $l_z, $l_not_z );
                $builder->emit_label($l_z);
                $builder->emit( 'builtin_print_char', 'void', [48] );
                $builder->emit( 'leave_func',         'void', [0] );
                $builder->emit_label($l_not_z);
                my $buf      = $builder->emit( 'sys_alloc', 'ptr', [32] );
                my $buf_slot = $driver->alloc_local_slot();
                $builder->emit( 'local_store', 'void', [ $buf_slot, $buf ] );
                my $idx      = $builder->emit( 'constant', 'i64', [0] );
                my $idx_slot = $driver->alloc_local_slot();
                $builder->emit( 'local_store', 'void', [ $idx_slot, $idx ] );
                my $n_slot = $driver->alloc_local_slot();
                $builder->emit( 'local_store', 'void', [ $n_slot, $n ] );
                my $l1 = $builder->new_label();
                my $l2 = $builder->new_label();
                $builder->emit_label($l1);
                my $curr_n   = $builder->emit( 'local_load', 'i64', [$n_slot] );
                my $rem      = $builder->emit( 'mod',        'i64', [ $curr_n, 10 ] );
                my $char_val = $builder->emit( 'add',        'i64', [ $rem,    48 ] );
                my $curr_buf = $builder->emit( 'local_load', 'ptr', [$buf_slot] );
                my $curr_idx = $builder->emit( 'local_load', 'i64', [$idx_slot] );
                $builder->emit( 'store_mem_byte', 'void', [ $curr_buf, $curr_idx, $char_val ] );
                $curr_idx = $builder->emit( 'add', 'i64', [ $curr_idx, 1 ] );
                $builder->emit( 'local_store', 'void', [ $idx_slot, $curr_idx ] );
                $curr_n = $builder->emit( 'div', 'i64', [ $curr_n, 10 ] );
                $builder->emit( 'local_store', 'void', [ $n_slot, $curr_n ] );
                $builder->emit_cond_br( $builder->emit( 'cmp_gt', 'Int', [ $curr_n, 0 ] ), $l1, $l2 );
                $builder->emit_label($l2);
                my $l3 = $builder->new_label();
                my $l4 = $builder->new_label();
                $builder->emit_label($l3);
                $curr_idx = $builder->emit( 'local_load', 'i64', [$idx_slot] );
                $curr_idx = $builder->emit( 'sub', 'i64', [ $curr_idx, 1 ] );
                $builder->emit( 'local_store', 'void', [ $idx_slot, $curr_idx ] );
                $curr_buf = $builder->emit( 'local_load', 'ptr', [$buf_slot] );
                $builder->emit( 'builtin_print_char', 'void', [ $builder->emit( 'load_mem_byte', 'Int', [ $curr_buf, $curr_idx ] ) ] );
                $builder->emit_cond_br( $builder->emit( 'cmp_gt', 'Int', [ $curr_idx, 0 ] ), $l3, $l4 );
                $builder->emit_label($l4);
                $builder->emit( 'leave_func', 'void', [0] );
            }

            # --- [6] Fiber New (Spilled Version) ---
            {
                $driver->reset_locals();
                $builder->emit_label('M_fiber_new');
                $builder->emit( 'enter_func', 'void', [] );
                my $func_ptr_reg = $builder->emit( 'get_arg', 'i64', [0] );
                my $func_slot    = $driver->alloc_local_slot();
                $builder->emit( 'local_store', 'void', [ $func_slot, $func_ptr_reg ] );
                my $fcb      = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', 64 ] );
                my $fcb_slot = $driver->alloc_local_slot();
                $builder->emit( 'local_store', 'void', [ $fcb_slot, $fcb ] );
                my $mstack  = $builder->emit( 'sys_alloc',  'ptr', [65536] );
                my $fcb_reg = $builder->emit( 'local_load', 'ptr', [$fcb_slot] );
                my $top     = $builder->emit( 'add',        'ptr', [ $mstack, 65536 ] );
                $builder->emit( 'store_mem_disp', 'void', [ $fcb_reg, $driver->fcb_offset('stack_base'),  $top ] );
                $builder->emit( 'store_mem_disp', 'void', [ $fcb_reg, $driver->fcb_offset('stack_limit'), $mstack ] );

                # X64 Entry Alignment:
                # The 'ret' in M_fiber_switch will pop the RIP and then the stack
                # must be 16-byte aligned. So RIP is at top - 8.
                my $rip_loc     = $builder->emit( 'sub',        'ptr', [ $top, 8 ] );
                my $actual_func = $builder->emit( 'local_load', 'i64', [$func_slot] );
                $builder->emit( 'store_mem_disp', 'void', [ $rip_loc, 0, $actual_func ] );

                # The Register Context block sits immediately below the RIP
                my $ctx_size       = $driver->context_size();
                my $reg_block      = $builder->emit( 'sub', 'ptr', [ $rip_loc, $ctx_size ] );
                my $reg_block_slot = $driver->alloc_local_slot();
                $builder->emit( 'local_store', 'void', [ $reg_block_slot, $reg_block ] );

                # Zero-init context
                my $zero = $builder->emit( 'constant', 'i64', [0] );
                for ( my $o = 0; $o < $ctx_size; $o += 8 ) {
                    $builder->emit( 'store_mem_disp', 'void', [ $reg_block, $o, $zero ] );
                }

                # Set initial Isolate Context (r14) and Frame Pointer (rbp)
                my $iso_val          = $builder->emit( 'get_isolate_ctx', 'ptr', [] );
                my $iso_name         = ( $driver->arch eq 'x64' ) ? 'r14' : 'x27';
                my $iso_offset       = $driver->context_offset($iso_name);
                my $reg_block_reload = $builder->emit( 'local_load', 'ptr', [$reg_block_slot] );
                $builder->emit( 'store_mem_disp', 'void', [ $reg_block_reload, $iso_offset, $iso_val ] );
                my $fp_name   = ( $driver->arch eq 'x64' ) ? 'rbp' : 'x29';
                my $fp_offset = $driver->context_offset($fp_name);
                $builder->emit( 'store_mem_disp', 'void', [ $reg_block_reload, $fp_offset, $reg_block_reload ] );

                # Setup GC Shadow Stack
                my $shadow   = $builder->emit( 'call_func',  'ptr', [ 'M_gc_alloc', 65536 ] );
                my $fcb_reg2 = $builder->emit( 'local_load', 'ptr', [$fcb_slot] );
                $builder->emit( 'store_mem_disp', 'void', [ $fcb_reg2, $driver->fcb_offset('shadow_base'), $shadow ] );
                $builder->emit( 'store_mem_disp', 'void', [ $fcb_reg2, $driver->fcb_offset('shadow_ptr'),  $shadow ] );

                # Link Fiber
                my $iso_val2  = $builder->emit( 'get_isolate_ctx', 'ptr', [] );
                my $prev_head = $builder->emit( 'load_mem_disp',   'ptr', [ $iso_val2, $driver->iso_offset('fiber_head') ] );
                $builder->emit( 'store_mem_disp', 'void', [ $fcb_reg2, $driver->fcb_offset('next'),       $prev_head ] );
                $builder->emit( 'store_mem_disp', 'void', [ $iso_val2, $driver->iso_offset('fiber_head'), $fcb_reg2 ] );

                # Set the SP in the FCB
                my $reg_block_final = $builder->emit( 'local_load', 'ptr', [$reg_block_slot] );
                $builder->emit( 'store_mem_disp', 'void', [ $fcb_reg2, $driver->fcb_offset('sp'), $reg_block_final ] );
                $builder->emit( 'leave_func',     'void', [$fcb_reg2] );
            }

            # --- [7] Dynamic Printer ---
            {
                $driver->reset_locals();
                $builder->emit_label('M_print_any');
                $builder->emit( 'enter_func', 'void', [] );
                my $val_reg   = $builder->emit( 'get_arg',  'i64', [0] );
                my $threshold = $builder->emit( 'constant', 'i64', [1000000] );
                my $is_ptr    = $builder->emit( 'cmp_gt',   'Int', [ $val_reg, $threshold ] );
                my $l_ptr     = $builder->new_label();
                my $l_int     = $builder->new_label();
                my $l_end     = $builder->new_label();
                $builder->emit_cond_br( $is_ptr, $l_ptr, $l_int );
                $builder->emit_label($l_ptr);
                $builder->emit( 'builtin_print', 'void', [$val_reg] );
                $builder->emit_jump($l_end);
                $builder->emit_label($l_int);
                $builder->emit( 'call_func', 'void', [ 'M_print_int', $val_reg ] );
                $builder->emit_jump($l_end);
                $builder->emit_label($l_end);
                $builder->emit( 'leave_func', 'void', [0] );
            }
        }

        method capture_fragment( $label, $logic_sub ) {

            # 1. Save the current state of the main IR builder
            my @saved_instructions = $builder->instructions;

            # 2. Clear instructions to start a fresh "fragment"
            $builder->set_instructions();

            # 3. Execute the code generation logic for the sub/fiber
            $logic_sub->();

            # 4. Extract the generated fragment instructions
            my @captured = $builder->instructions;
            push @fragments, \@captured;

            # 5. Restore the main IR builder to its previous state
            $builder->set_instructions(@saved_instructions);
        }

        method _lower_logical($node) {
            my $is_and   = $node->op eq '&&';
            my $res_slot = $driver->alloc_local_slot();
            my $l_short  = $builder->new_label();
            my $l_end    = $builder->new_label();

            # 1. Evaluate the left side
            my ( $l_reg, $l_typ ) = $self->lower( $node->left );

            # 2. Short-circuit logic:
            # AND: if left is 0, jump to short-circuit (result = 0)
            # OR:  if left is non-0, jump to short-circuit (result = 1)
            if ($is_and) {
                $builder->emit_cond_br( $l_reg, $builder->new_label(), $l_short );
            }
            else {
                $builder->emit_cond_br( $l_reg, $l_short, $builder->new_label() );
            }

            # 3. Handle Right side (only reached if no short-circuit)
            $builder->emit_label( $builder->last_instruction->{ ( $is_and ? 'true_l' : 'false_l' ) } );
            my ( $r_reg, $r_typ ) = $self->lower( $node->right );

            # Use comparison to ensure the result is strictly 1 or 0
            my $bool_r = $builder->emit( 'cmp_ne', 'Int', [ $r_reg, 0 ] );
            $builder->emit( 'local_store', 'void', [ $res_slot, $bool_r ] );
            $builder->emit_jump($l_end);

            # 4. Handle Short-circuit path
            $builder->emit_label($l_short);
            my $short_val = $builder->emit( 'constant', 'i64', [ $is_and ? 0 : 1 ] );
            $builder->emit( 'local_store', 'void', [ $res_slot, $short_val ] );

            # 5. Done
            $builder->emit_label($l_end);
            return ( $builder->emit( 'local_load', 'Int', [$res_slot] ), 'Int' );
        }

        # --- Literal Handlers ---
        method lower_Const($node) {
            if ( $node->type eq 'String' ) {
                my $reg = $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string( $node->value ) ] );
                return ( $reg, 'String' );
            }
            if ( $node->type eq 'Class' ) {
                return ( $builder->emit( 'constant', 'i64', [0] ), $node->value );
            }

            # Int / Bool
            return ( $builder->emit( 'constant', 'i64', [ $node->value ] ), 'Int' );
        }

        # --- Variable Handlers ---
        method lower_Var($node) {
            my $sym = $current_scope->resolve( $node->name ) // die "Undeclared variable: " . $node->name . "\n";

            # Field access via $self
            if ( defined $sym->stack_offset && $sym->stack_offset < 0 ) {
                my $self_sym = $current_scope->resolve('$self');
                my $self_ptr = $builder->emit( 'local_load', 'ptr', [ $self_sym->stack_offset ] );
                return ( $builder->emit( 'load_mem_disp', 'Any', [ $self_ptr, abs( $sym->stack_offset ) ] ), 'Any' );
            }

            # Persistent state access
            if ( $sym->is_state ) {
                my $sb = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('state_ptr') ] );
                return ( $builder->emit( 'load_mem_disp', $sym->type, [ $sb, 4096 + ( $sym->state_idx * 8 ) ] ), $sym->type );
            }

            # Lexical local
            return ( $builder->emit( 'local_load', $sym->type, [ $sym->stack_offset ] ), $sym->type );
        }

        method lower_VarDecl($node) {
            my ( $v_reg, $v_typ ) = $self->lower( $node->value );
            my $decl_type = $node->type eq 'Any' ? $v_typ : $node->type;
            my $slot      = $driver->alloc_local_slot();
            $current_scope->define( $node->name, $decl_type, 0, undef, $slot );
            $builder->emit( 'local_store', 'void', [ $slot, $v_reg ] );
            return ( undef, 'void' );
        }

        method lower_StateDecl($node) {
            my $idx = $state_count++;
            $current_scope->define( $node->name, $node->type, 1, $idx, undef );
            my $l_init = $builder->new_label();
            my $l_done = $builder->new_label();
            my $sb     = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('state_ptr') ] );

            # Check if initialized (byte at state_ptr + idx)
            $builder->emit_cond_br( $builder->emit( 'load_mem_byte', 'Int', [ $sb, $idx ] ), $l_done, $l_init );
            $builder->emit_label($l_init);
            my ( $v_reg, $v_typ ) = $self->lower( $node->value );
            $builder->emit( 'store_mem_byte', 'void', [ $sb, $idx, 1 ] );
            $builder->emit( 'store_mem_disp', 'void', [ $sb, 4096 + ( $idx * 8 ), $v_reg ] );
            $builder->emit_jump($l_done);
            $builder->emit_label($l_done);
            return ( $builder->emit( 'load_mem_disp', $node->type, [ $sb, 4096 + ( $idx * 8 ) ] ), $node->type );
        }

        method lower_Assignment($node) {
            my ( $v_reg, $v_typ ) = $self->lower( $node->value );
            my $sym = $current_scope->resolve( $node->name ) // die "Undeclared variable: " . $node->name . "\n";
            if ( defined $sym->stack_offset && $sym->stack_offset < 0 ) {

                # Instance Field logic
                my $self_sym = $current_scope->resolve('$self') // die "Cannot assign field outside method";
                my $self_ptr = $builder->emit( 'local_load', 'ptr', [ $self_sym->stack_offset ] );
                $builder->emit( 'store_mem_disp', 'void', [ $self_ptr, abs( $sym->stack_offset ), $v_reg ] );
            }
            elsif ( $sym->is_state ) {

                # Persistent state logic
                my $sb = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('state_ptr') ] );
                $builder->emit( 'store_mem_disp', 'void', [ $sb, 4096 + ( $sym->state_idx * 8 ), $v_reg ] );
            }
            else {
                # CRITICAL: This updates the actual stack memory slot
                $builder->emit( 'local_store', 'void', [ $sym->stack_offset, $v_reg ] );
            }

            # Return the register and type so assignments can be used in expressions
            return ( $v_reg, $sym->type );
        }

        # --- Operator Handlers ---
        method lower_UnaryOp($node) {
            my ( $reg, $type ) = $self->lower( $node->expr );
            if ( $node->op eq '!' ) {
                return ( $builder->emit( 'cmp_eq', 'Int', [ $reg, 0 ] ), 'Int' );
            }
            die "Unary operator " . $node->op . " not implemented";
        }

        method lower_BinOp($node) {

            # Handle Logical Short-circuiting (&& and ||)
            if ( $node->op eq '&&' || $node->op eq '||' ) {
                return $self->_lower_logical($node);
            }

            # Math and Comparison ops
            my ( $l_reg, $l_typ ) = $self->lower( $node->left );
            my ( $r_reg, $r_typ ) = $self->lower( $node->right );
            my $op_map = {
                '+'  => 'add',
                '-'  => 'sub',
                '*'  => 'mul',
                '/'  => 'div',
                '%'  => 'mod',
                '==' => 'cmp_eq',
                '!=' => 'cmp_ne',
                '<'  => 'cmp_lt',
                '>'  => 'cmp_gt',
                '<=' => 'cmp_le',
                '>=' => 'cmp_ge'
            };
            if ( !exists $op_map->{ $node->op } ) {
                die "Lowering Error: Binary operator " . $node->op . " not supported in BinOp node.";
            }
            return ( $builder->emit( $op_map->{ $node->op }, 'i64', [ $l_reg, $r_reg ] ), 'Int' );
        }

        method lower_Ternary($node) {
            my $res_slot = $driver->alloc_local_slot();
            my $l_then   = $builder->new_label();
            my $l_else   = $builder->new_label();
            my $l_end    = $builder->new_label();
            my ( $c_reg, $c_typ ) = $self->lower( $node->cond );
            $builder->emit_cond_br( $c_reg, $l_then, $l_else );
            $builder->emit_label($l_then);
            my ( $t_reg, $t_typ ) = $self->lower( $node->then );
            $builder->emit( 'local_store', 'void', [ $res_slot, $t_reg ] );
            $builder->emit_jump($l_end);
            $builder->emit_label($l_else);
            my ( $e_reg, $e_typ ) = $self->lower( $node->else );
            $builder->emit( 'local_store', 'void', [ $res_slot, $e_reg ] );
            $builder->emit_label($l_end);
            return ( $builder->emit( 'local_load', 'Any', [$res_slot] ), 'Any' );
        }

        # --- Control Flow Handlers ---
        method lower_Block($node) {
            $current_scope = Brocken::Scope->new( parent => $current_scope );
            my @res = $self->lower_block( $node->statements );
            $current_scope = $current_scope->parent;
            return @res;
        }

        method lower_If($node) {
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

        method lower_While($node) {
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

        # --- Call and Routine Handlers ---
        method lower_Call($node) {

            # 1. Handle Built-ins (say, print, transfer)
            if ( $node->name eq 'transfer' ) {
                my ( $f_reg, $f_typ ) = $self->lower( $node->args->[0] );
                my ( $v_reg, $v_typ ) = $self->lower( $node->args->[1] );
                return ( $builder->emit( 'call_func', 'Int', [ 'M_fiber_switch', $f_reg, $v_reg ] ), 'Any' );
            }
            if ( $node->name eq 'say' || $node->name eq 'print' ) {
                my ( $r, $t ) = $self->lower( $node->args->[0] );

                # If it's a constant string, use the fast path
                if ( $t eq 'String' ) {
                    $builder->emit( 'builtin_print', 'void', [$r] );
                }

                # If it's an Int, use the conversion helper
                elsif ( $t eq 'Int' ) {
                    $builder->emit( 'call_func', 'void', [ 'M_print_int', $r ] );
                }

                # Fallback for dynamic 'Any' types
                else {
                    $builder->emit( 'call_func', 'void', [ 'M_print_any', $r ] );
                }

                # 'say' adds a newline
                if ( $node->name eq 'say' ) {
                    my $nl = $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string("\n") ] );
                    $builder->emit( 'builtin_print', 'void', [$nl] );
                }
                return ( undef, 'void' );
            }

            # 2. Handle User Subroutines (prefixed with M_)
            my @args = map { ( $self->lower($_) )[0] } @{ $node->args };
            return ( $builder->emit( 'call_func', 'i64', [ 'M_' . $node->name, @args ] ), 'Any' );
        }

        method lower_Return($node) {
            die "Return outside sub" if $routine_depth == 0;
            my ( $ret_val, $typ ) = $self->lower( $node->expr );
            if ( $routine_types[-1] eq 'fiber' ) {

                # Return from fiber context
                my $fcb    = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('current_fcb') ] );
                my $caller = $builder->emit( 'load_mem_disp', 'ptr', [ $fcb, $driver->fcb_offset('caller') ] );
                $builder->emit( 'call_func', 'Any', [ 'M_fiber_switch', $caller, $ret_val ] );
                $builder->emit( 'exit_program', 'void', [0] );
            }
            else {
                $builder->emit( 'leave_func', 'void', [$ret_val] );
            }
            return ( undef, 'void' );
        }

        method lower_Exit($node) {
            my ( $val, $typ ) = $self->lower( $node->expr );
            $builder->emit( 'exit_program', 'void', [$val] );
            return ( undef, 'void' );
        }

        # --- OO Handlers ---
        method lower_ClassDecl($node) {
            my $cinfo = $class_info{ $node->name };
            my %field_map;
            my $offset = 16;    # 0=VTable, 8=ArraySize
            for my $f ( @{ $node->fields } ) { $field_map{ $f->name } = $offset; $offset += 8; }

            # 1. Constructor
            $driver->reset_locals();
            $builder->emit_label( 'M_' . $node->name . '::new' );
            $builder->emit( 'enter_func', 'void', [] );
            my $obj_sz = $builder->emit( 'constant',  'i64', [$offset] );
            my $obj    = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', $obj_sz ] );

            # Set VTable
            if ( scalar( @{ $cinfo->{method_names} } ) > 0 ) {
                my $state_mem = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('state_ptr') ] );
                my $vt_ptr    = $builder->emit( 'load_mem_disp', 'ptr', [ $state_mem, $cinfo->{id} * 8 ] );
                $builder->emit( 'store_mem_disp', 'void', [ $obj, 0, $vt_ptr ] );
            }
            else {
                $builder->emit( 'store_mem_disp', 'void', [ $obj, 0, $builder->emit( 'constant', 'i64', [0] ) ] );
            }
            $builder->emit( 'store_mem_disp', 'void', [ $obj, 8, $builder->emit( 'constant', 'i64', [0] ) ] );
            $builder->emit( 'leave_func',     'void', [$obj] );

            # 2. Methods
            push @routine_types, 'method';
            for my $m ( @{ $node->methods } ) {
                $driver->reset_locals();
                $builder->emit_label( 'M_' . $node->name . '::' . $m->name );
                $builder->emit( 'enter_func', 'void', [] );
                $current_scope = Brocken::Scope->new( parent => $current_scope );
                $routine_depth++;

                # Define $self and fields
                my $self_slot = $driver->alloc_local_slot();
                $current_scope->define( '$self', 'ptr', 0, undef, $self_slot );
                $builder->emit( 'local_store', 'void', [ $self_slot, $builder->emit( 'get_arg', 'ptr', [0] ) ] );
                for my $fname ( keys %field_map ) { $current_scope->define( $fname, 'Any', 0, undef, -$field_map{$fname} ); }

                # Define params
                my $arg_idx = 1;    # Arg 0 is $self
                for my $p ( @{ $m->params } ) {
                    my $slot = $driver->alloc_local_slot();
                    $current_scope->define( $p->{name}, $p->{type}, 0, undef, $slot );
                    $builder->emit( 'local_store', 'void', [ $slot, $builder->emit( 'get_arg', 'i64', [ $arg_idx++ ] ) ] );
                }
                $self->lower_block( $m->body->statements );
                $builder->emit( 'leave_func', 'void', [0] );
                $routine_depth--;
                $current_scope = $current_scope->parent;
            }
            pop @routine_types;
            return ( undef, 'void' );
        }

        method lower_Method($node) {

            # Global sub transformed to a static method
            push @routine_types, 'method';
            $driver->reset_locals();
            $builder->emit_label( 'M_' . $node->name );
            $builder->emit( 'enter_func', 'void', [] );
            $current_scope = Brocken::Scope->new( parent => $current_scope );
            $routine_depth++;
            my $arg_idx = 0;

            for my $p ( @{ $node->params } ) {
                my $slot = $driver->alloc_local_slot();
                $current_scope->define( $p->{name}, $p->{type}, 0, undef, $slot );
                $builder->emit( 'local_store', 'void', [ $slot, $builder->emit( 'get_arg', 'i64', [ $arg_idx++ ] ) ] );
            }
            $self->lower_block( $node->body->statements );
            $builder->emit( 'leave_func', 'void', [0] );
            $routine_depth--;
            $current_scope = $current_scope->parent;
            pop @routine_types;
            return ( undef, 'void' );
        }

        method lower_MethodCall($node) {

            # Static constructor check
            if ( $node->name eq 'new' && $node->invocant isa Brocken::AST::Const && $node->invocant->type eq 'Class' ) {
                my $cname = $node->invocant->value;
                my $ptr   = $builder->emit( 'call_func', 'ptr', ["M_${cname}::new"] );
                $builder->emit( 'shadow_push', 'void', [$ptr] );
                return ( $ptr, $cname );
            }
            my ( $obj_reg, $obj_typ ) = $self->lower( $node->invocant );
            my @args     = map { ( $self->lower($_) )[0] } @{ $node->args };
            my $gidx     = $global_methods{ $node->name } // die "Method '" . $node->name . "' not found in global registry";
            my $vt_ptr   = $builder->emit( 'load_mem_disp', 'ptr', [ $obj_reg, 0 ] );
            my $func_ptr = $builder->emit( 'load_mem_disp', 'ptr', [ $vt_ptr,  $gidx * 8 ] );
            return ( $builder->emit( 'call_reg', 'i64', [ $func_ptr, $obj_reg, @args ] ), 'Any' );
        }

        # --- Fiber Handlers ---
        method lower_FiberBlock($node) {
            my $fib_label  = $builder->new_label();
            my $skip_label = $builder->new_label();
            $builder->emit_jump($skip_label);

            # Fragment Capture logic
            my @main_instructions = $builder->instructions;
            $builder->set_instructions();
            my $saved_local_ptr = $driver->local_ptr;
            $driver->reset_locals();
            $builder->emit_label($fib_label);
            $builder->emit( 'enter_func', 'void', [] );
            $current_scope = Brocken::Scope->new( parent => $current_scope );
            $routine_depth++;
            push @routine_types, 'fiber';

            # Initial input from transfer
            if ( scalar @{ $node->params } > 0 ) {
                my $input_val = $builder->emit( 'mov', 'Any', ['rax'] );    # Fiber switch moves input to rax
                my $p         = $node->params->[0];
                my $slot      = $driver->alloc_local_slot();
                $current_scope->define( $p->{name}, $p->{type}, 0, undef, $slot );
                $builder->emit( 'local_store', 'void', [ $slot, $input_val ] );
            }
            my ( $res, $type ) = $self->lower_block( $node->body->statements );

            # Auto-return at end of block
            my $fcb    = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('current_fcb') ] );
            my $caller = $builder->emit( 'load_mem_disp', 'ptr', [ $fcb, $driver->fcb_offset('caller') ] );
            $builder->emit( 'call_func', 'Any', [ 'M_fiber_switch', $caller, $res // 0 ] );
            $builder->emit( 'exit_program', 'void', [0] );
            pop @routine_types;
            $routine_depth--;
            $current_scope = $current_scope->parent;
            my @fiber_instructions = $builder->instructions;
            $builder->set_instructions( @main_instructions, @fiber_instructions );
            $builder->emit_label($skip_label);
            $driver->set_local_ptr($saved_local_ptr);
            return ( $builder->emit( 'call_func', 'ptr', [ 'M_fiber_new', $fib_label ] ), 'Fiber' );
        }

        method lower_Yield($node) {
            my ( $y_val, $y_typ ) = $self->lower( $node->expr );
            my $fcb    = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('current_fcb') ] );
            my $caller = $builder->emit( 'load_mem_disp', 'ptr', [ $fcb, $driver->fcb_offset('caller') ] );

            # Fiber switch returns the value passed into the fiber back into a register
            return ( $builder->emit( 'call_func', 'Int', [ 'M_fiber_switch', $caller, $y_val ] ), 'Int' );
        }

        # --- Data Structure Handlers ---
        method lower_ArrayLiteral($node) {
            my $count   = scalar @{ $node->elements };
            my $size    = 16 + ( $count * 8 );
            my $sz_reg  = $builder->emit( 'constant',  'i64', [$size] );
            my $arr_ptr = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', $sz_reg ] );
            $builder->emit( 'shadow_push',    'void', [$arr_ptr] );
            $builder->emit( 'store_mem_disp', 'void', [ $arr_ptr, 0, $sz_reg ] );
            $builder->emit( 'store_mem_disp', 'void', [ $arr_ptr, 8, $builder->emit( 'constant', 'i64', [$count] ) ] );
            my $idx = 0;

            for my $el ( @{ $node->elements } ) {
                my ( $el_reg, $el_typ ) = $self->lower($el);
                $builder->emit( 'store_mem_disp', 'void', [ $arr_ptr, 16 + ( $idx++ * 8 ), $el_reg ] );
            }
            return ( $arr_ptr, 'Array' );
        }

        method lower_Map($node) {

            # Loop fusion is handled by the Optimizer, so we just emit a map_op placeholder
            my ( $src_reg, $src_typ ) = $self->lower( $node->source );
            my $res_reg = $builder->emit( 'map_op', 'Array', [ $src_reg, $node->expr ] );
            return ( $res_reg, 'Array' );
        }

        method lower_AnonSub($node) {
            my $label   = "L_ANON_" . ++$anon_counter;
            my $old_ptr = $driver->local_ptr;
            $self->capture_fragment(
                $label,
                sub {
                    $driver->reset_locals();
                    $builder->emit_label($label);
                    $builder->emit( 'enter_func', 'void', [] );
                    $current_scope = Brocken::Scope->new( parent => $current_scope );
                    $routine_depth++;
                    my $arg_idx = 0;
                    for my $p ( @{ $node->params } ) {
                        my $slot = $driver->alloc_local_slot();
                        $current_scope->define( $p->{name}, $p->{type}, 0, undef, $slot );
                        $builder->emit( 'local_store', 'void', [ $slot, $builder->emit( 'get_arg', 'i64', [ $arg_idx++ ] ) ] );
                    }
                    $self->lower_block( $node->body->statements );
                    $builder->emit( 'leave_func', 'void', [0] );
                    $routine_depth--;
                    $current_scope = $current_scope->parent;
                }
            );
            $driver->set_local_ptr($old_ptr);
            return ( $builder->emit( 'load_func_addr', 'ptr', [$label] ), 'ptr' );
        }

        method lower_AnonCall($node) {
            my ( $ptr_reg, $ptr_typ ) = $self->lower( $node->invocant );
            my @args = map { ( $self->lower($_) )[0] } @{ $node->args };
            return ( $builder->emit( 'call_reg', 'i64', [ $ptr_reg, @args ] ), 'Any' );
        }
    }
}
1;
