package Brocken::Compiler::Runtime;
use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Brocken::Core::IR::Builder;

class Brocken::Compiler::Runtime {
    field $builder                : param;
    field $driver                 : param;
    field $data_segment           : param;
    field $undef_ptr_offset       : param;
    field $line_table_ptr_offset  : param;
    field $line_table_size_offset : param;
    field $state_count            : param;
    field $our_var_next_offset    : param;
    field $stack_ptr_offset       : param;

    method inject_runtime() {

        # Discard M_gc_mark_obj and M_gc_sweep as they are obsolete
        $self->inject_runtime_gc_collect();
        $self->inject_runtime_gc_alloc();

        # Generational Nursery & Semi-Space GC
        $self->inject_runtime_gc_alloc_tenured();
        $self->inject_runtime_minor_collect();
        $self->inject_runtime_promote_object();
        $self->inject_runtime_evacuate_major();
        $self->inject_runtime_init_env();
        $self->inject_runtime_init_argv();
        $self->inject_runtime_print_int();
        $self->inject_runtime_float_to_str();
        $self->inject_runtime_to_string();
        $self->inject_runtime_print_any();
        $self->inject_runtime_dump();
        $self->inject_runtime_ddx();
        $self->inject_runtime_dd();
        $self->inject_runtime_new_fiber();
        $self->inject_runtime_concat();
        $self->inject_runtime_unwind();
        $self->inject_runtime_str_eq();
        $self->inject_runtime_str_cmp();
        $self->inject_runtime_str_slice();
        $self->inject_runtime_hash_djb2();
        $self->inject_runtime_hash_new();
        $self->inject_runtime_hash_lookup_slot();
        $self->inject_runtime_hash_lookup();
        $self->inject_runtime_hash_insert();
        $self->inject_runtime_hash_resize();
        $self->inject_runtime_hash_keys();
        $self->inject_runtime_hash_values();
        $self->inject_runtime_hash_exists();
        $self->inject_runtime_hash_delete();
        $self->inject_runtime_thread_entry();
        $self->inject_runtime_boxing();
        $self->_emit_runtime_init_sub();
    }

    method inject_runtime_boxing() {
        $self->inject_runtime_box_float();
        $self->inject_runtime_unbox_float();
        $self->inject_runtime_box_pointer();
        $self->inject_runtime_unbox_pointer();
    }

    method inject_runtime_box_float() {
        $driver->reset_locals();
        $builder->emit_label('M_box_float');
        $builder->emit( 'enter_func', 'void', [] );
        my $v   = $builder->emit( 'get_arg',   'double', [0] );
        my $psz = $builder->emit( 'constant',  'i64',    [ 24 | hex("E000000000000000") ] );    # size=24, Special=1, Leaf=1
        my $obj = $builder->emit( 'call_func', 'ptr',    [ 'M_gc_alloc', $psz ] );
        $builder->emit( 'store_mem_disp', 'void', [ $obj, 0, 1 ] );                             # TypeID = 1 (Float)
        $builder->emit( 'store_mem_disp', 'void', [ $obj, 8, $v ] );
        $builder->emit( 'leave_func',     'ptr',  [$obj] );
    }

    method inject_runtime_unbox_float() {
        $driver->reset_locals();
        $builder->emit_label('M_unbox_float');
        $builder->emit( 'enter_func', 'void', [] );
        my $v     = $builder->emit( 'get_arg', 'i64', [0] );
        my $l_box = $builder->new_label();
        my $l_raw = $builder->new_label();

        # If bit 0 is 1, it's an SMI (not a float). But let's assume it's raw double if bit 0 is 1?
        # Actually, raw doubles can have bit 0 set.
        # Best check: if it looks like a Brocken object pointer.
        # For simplicity in FFI, let's assume if bit 0 is 0 and it's not NULL, it might be a box.
        $builder->emit_cond_br( $builder->emit( 'and', 'i64', [ $v, 1 ] ), $l_raw, $l_box );
        $builder->emit_label($l_box);
        my $l_not_null = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_ne', 'Int', [ $v, 0 ] ), $l_not_null, $l_raw );
        $builder->emit_label($l_not_null);

        # It's a pointer. Check if it's a Special Leaf.
        my $hdr       = $builder->emit( 'load_mem_disp', 'i64', [ $v,   -8 ] );
        my $is_spec   = $builder->emit( 'and',           'i64', [ $hdr, $builder->emit( 'constant', 'i64', [ 1 << 61 ] ) ] );
        my $l_is_spec = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_ne', 'Int', [ $is_spec, 0 ] ), $l_is_spec, $l_raw );
        $builder->emit_label($l_is_spec);
        $builder->emit( 'leave_func', 'double', [ $builder->emit( 'load_mem_disp', 'double', [ $v, 8 ] ) ] );
        $builder->emit_label($l_raw);
        $builder->emit( 'leave_func', 'double', [$v] );
    }

    method inject_runtime_box_pointer() {
        $driver->reset_locals();
        $builder->emit_label('M_box_pointer');
        $builder->emit( 'enter_func', 'void', [] );
        my $v   = $builder->emit( 'get_arg',   'ptr', [0] );
        my $psz = $builder->emit( 'constant',  'i64', [ 24 | hex("E000000000000000") ] );    # size=24, Special=1, Leaf=1
        my $obj = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', $psz ] );
        $builder->emit( 'store_mem_disp', 'void', [ $obj, 0, 2 ] );                          # TypeID = 2 (Pointer)
        $builder->emit( 'store_mem_disp', 'void', [ $obj, 8, $v ] );
        $builder->emit( 'leave_func',     'ptr',  [$obj] );
    }

    method inject_runtime_unbox_pointer() {
        $driver->reset_locals();
        $builder->emit_label('M_unbox_pointer');
        $builder->emit( 'enter_func', 'void', [] );
        my $v     = $builder->emit( 'get_arg', 'i64', [0] );
        my $l_box = $builder->new_label();
        my $l_raw = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'and', 'i64', [ $v, 1 ] ), $l_raw, $l_box );
        $builder->emit_label($l_box);
        my $l_not_null = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_ne', 'Int', [ $v, 0 ] ), $l_not_null, $l_raw );
        $builder->emit_label($l_not_null);
        my $hdr       = $builder->emit( 'load_mem_disp', 'i64', [ $v,   -8 ] );
        my $is_spec   = $builder->emit( 'and',           'i64', [ $hdr, $builder->emit( 'constant', 'i64', [ 1 << 61 ] ) ] );
        my $l_is_spec = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_ne', 'Int', [ $is_spec, 0 ] ), $l_is_spec, $l_raw );
        $builder->emit_label($l_is_spec);
        $builder->emit( 'leave_func', 'ptr', [ $builder->emit( 'load_mem_disp', 'ptr', [ $v, 8 ] ) ] );
        $builder->emit_label($l_raw);
        $builder->emit( 'leave_func', 'ptr', [$v] );
    }

    method inject_runtime_thread_entry() {
        $driver->reset_locals();
        $builder->emit_label('M_thread_entry');
        $builder->emit( 'enter_func', 'void', [] );

        # Save the raw function pointer passed as argument 1 by the OS thread spawner
        my $target_fn_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $target_fn_s, $builder->emit( 'get_arg', 'ptr', [0] ) ] );

        # Allocate and initialize a fresh, thread-local Isolate Context block (1024 bytes)
        my $iso = $builder->emit( 'intrinsic_alloc', 'ptr', [1024] );
        $builder->emit( 'set_isolate_ctx', 'void', [$iso] );

        # Initialize the thread's own independent nursery and tenured heap
        $builder->emit( 'call_func', 'void', ['M_runtime_init_thread'] );

        # Call the target Brocken function pointer!
        my $target_fn = $builder->emit( 'local_load', 'ptr', [$target_fn_s] );
        $builder->emit( 'call_reg', 'void', [$target_fn] );

        # Clean up and exit thread
        $builder->emit( 'leave_func', 'void', [] );

        # Inject M_runtime_init_thread
        $self->inject_runtime_init_thread();
    }

    method inject_runtime_init_thread() {
        $driver->reset_locals();
        $builder->emit_label('M_runtime_init_thread');
        $builder->emit( 'enter_func', 'void', [] );
        my $iso = $builder->emit( 'get_isolate_ctx', 'ptr', [] );
        my $ms  = $builder->emit( 'intrinsic_alloc', 'ptr', [1048576] );
        $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('mark_stack_base'),  $ms ] );
        $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('mark_stack_ptr'),   $ms ] );
        $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('mark_stack_limit'), $builder->emit( 'add', 'ptr', [ $ms, 1048576 ] ) ] );

        # --- Generational Nursery Initialization (64KB) ---
        my $raw_nursery = $builder->emit( 'intrinsic_alloc', 'ptr', [65536] );
        $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('nursery_base'),  $raw_nursery ] );
        $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('nursery_ptr'),   $raw_nursery ] );
        $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('nursery_limit'), $builder->emit( 'add', 'ptr', [ $raw_nursery, 65536 ] ) ] );

        # --- Tenured Heap Initialization (Two 2MB Semi-Spaces) ---
        my $raw_heap = $builder->emit( 'intrinsic_alloc', 'ptr', [4259840] );                     # Padded to prevent out-of-bounds on 64KB alignment
        my $mask     = $builder->emit( 'constant',        'i64', [ hex("FFFFFFFFFFFF0000") ] );
        my $hp       = $builder->emit( 'and',             'i64', [ $builder->emit( 'add', 'ptr', [ $raw_heap, 65535 ] ), $mask ] );
        $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('heap_base'),  $hp ] );
        $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('heap_ptr'),   $builder->emit( 'add', 'ptr', [ $hp, 1024 ] ) ] );
        $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('heap_limit'), $builder->emit( 'add', 'ptr', [ $hp, 2097152 ] ) ] );

        # Setup ToSpace boundaries
        my $ts_base = $builder->emit( 'add', 'ptr', [ $hp, 2097152 ] );
        $builder->emit( 'store_iso_disp', 'void', [ 88, $ts_base ] );
        $builder->emit( 'store_iso_disp', 'void', [ 96, $builder->emit( 'add', 'ptr', [ $ts_base, 2097152 ] ) ] );

        # --- Heap Block Signature ---
        $builder->emit( 'store_mem_disp', 'void', [ $hp, 8, $builder->emit( 'constant', 'i64', [0x424b4e4845415036] ) ] );
        my $stm = $builder->emit( 'intrinsic_alloc', 'ptr', [1048576] );
        $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('state_ptr'), $stm ] );
        my $fcb = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', $builder->emit( 'constant', 'i64', [ 64 | hex("C000000000000000") ] ) ] );
        $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('current_fcb'), $fcb ] );
        $builder->emit( 'store_mem_disp', 'void', [ $iso, $driver->iso_offset('fiber_head'), $fcb ] );
        my $sh = $builder->emit( 'intrinsic_alloc', 'ptr', [1048576] );
        $builder->emit( 'store_mem_disp', 'void', [ $fcb, $driver->fcb_offset('shadow_base'), $sh ] );
        $builder->emit( 'store_mem_disp', 'void', [ $fcb, $driver->fcb_offset('shadow_ptr'),  $sh ] );
        $builder->emit( 'store_mem_disp', 'void',
            [ $fcb, $driver->fcb_offset('wait_handle'), $builder->emit( 'intrinsic_create_wait_handle', 'ptr', [] ) ] );
        $builder->emit( 'leave_func', 'void', [] );
    }

    method inject_runtime_unwind() {
        $driver->reset_locals();
        $builder->emit_label('M_unwind');
        $builder->emit( 'enter_func', 'void', [] );
        my $fcb          = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('current_fcb') ] );
        my $msg_from_fcb = $builder->emit( 'load_mem_disp', 'Any', [ $fcb, $driver->fcb_offset('exception_obj') ] );
        my $msg_slot     = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $msg_slot, $msg_from_fcb ] );
        my $bp_slot = $driver->alloc_local_slot();
        my $my_bp   = $builder->emit( 'get_bp', 'ptr', [] );
        $builder->emit( 'local_store', 'void', [ $bp_slot, $my_bp ] );
        my $extab_ptr = $builder->emit( 'load_iso_disp',           'ptr', [ $driver->iso_offset('exception_table') ] );
        my $text_base = $builder->emit( 'intrinsic_get_text_base', 'ptr', [] );
        my $data_base = $builder->emit( 'load_data_addr',          'ptr', [0] );

        # Search Depth setup to prevent stack overflow crashes
        my $search_depth_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $search_depth_s, 0 ] );
        my $l_frame_loop = $builder->new_label();
        $builder->emit_label($l_frame_loop);
        my $curr_bp  = $builder->emit( 'local_load', 'ptr', [$bp_slot] );
        my $s_depth  = $builder->emit( 'local_load', 'i64', [$search_depth_s] );
        my $l_search = $builder->new_label();
        my $l_fatal  = $builder->new_label();

        # Or-combine termination conditions (curr_bp == 0 OR depth >= 30)
        my $is_done = $builder->emit( 'or', 'i64',
            [ $builder->emit( 'cmp_eq', 'Int', [ $curr_bp, 0 ] ), $builder->emit( 'cmp_ge', 'Int', [ $s_depth, 30 ] ) ] );
        $builder->emit_cond_br( $is_done, $l_fatal, $l_search );
        $builder->emit_label($l_fatal);
        my $l_custom     = $builder->new_label();
        my $l_default    = $builder->new_label();
        my $l_print_done = $builder->new_label();
        my $msg          = $builder->emit( 'local_load', 'ptr', [$msg_slot] );
        $builder->emit_cond_br( $builder->emit( 'cmp_ne', 'Int', [ $msg, 0 ] ), $l_custom, $l_default );
        $builder->emit_label($l_custom);
        $builder->emit( 'call_func', 'void', [ 'M_print_any', $builder->emit( 'local_load', 'Any', [$msg_slot] ) ] );
        $builder->emit_jump($l_print_done);
        $builder->emit_label($l_default);
        $builder->emit( 'intrinsic_print', 'void',
            [ $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string("FATAL: Unhandled Exception\n") ] ) ] );
        $builder->emit_label($l_print_done);

        # --- Start Unhandled Exception Stack-Trace Backtrace ---
        my $fn_rva     = $data_segment->add_string( $driver->source_file // "source.brocken" );
        my $trace_bp_s = $driver->alloc_local_slot();
        my $orig_my_bp = $builder->emit( 'get_bp', 'ptr', [] );
        $builder->emit( 'local_store', 'void', [ $trace_bp_s, $orig_my_bp ] );
        my $trace_depth_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $trace_depth_s, 0 ] );
        my $l_trace_loop = $builder->new_label();
        my $l_trace_done = $builder->new_label();
        $builder->emit_label($l_trace_loop);
        my $t_bp         = $builder->emit( 'local_load', 'ptr', [$trace_bp_s] );
        my $t_depth      = $builder->emit( 'local_load', 'i64', [$trace_depth_s] );
        my $l_trace_next = $builder->new_label();
        my $is_trace_done
            = $builder->emit( 'or', 'i64', [ $builder->emit( 'cmp_eq', 'Int', [ $t_bp, 0 ] ), $builder->emit( 'cmp_ge', 'Int', [ $t_depth, 30 ] ) ] );
        $builder->emit_cond_br( $is_trace_done, $l_trace_done, $l_trace_next );
        $builder->emit_label($l_trace_next);
        my $t_rip        = $builder->emit( 'load_mem_disp', 'ptr', [ $t_bp, $driver->rip_offset() ] );
        my $t_prev       = $builder->emit( 'load_mem_disp', 'ptr', [ $t_bp, $driver->prev_bp_offset() ] );
        my $t_rva        = $builder->emit( 'sub',            'i64', [ $builder->emit( 'sub', 'i64', [ $t_rip, $text_base ] ), 1 ] );
        my $rlt_ptr_addr = $builder->emit( 'load_data_addr', 'ptr', [$line_table_ptr_offset] );
        my $rlt_ptr      = $builder->emit( 'load_mem_disp',  'ptr', [ $rlt_ptr_addr, 0 ] );
        my $rlt_sz_addr  = $builder->emit( 'load_data_addr', 'ptr', [$line_table_size_offset] );
        my $rlt_sz       = $builder->emit( 'load_mem_disp',  'i64', [ $rlt_sz_addr, 0 ] );
        my $best_line_s  = $driver->alloc_local_slot();
        my $best_col_s   = $driver->alloc_local_slot();
        my $best_file_s  = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $best_line_s, 0 ] );
        $builder->emit( 'local_store', 'void', [ $best_col_s,  0 ] );
        $builder->emit( 'local_store', 'void', [ $best_file_s, 0 ] );
        my $idx_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $idx_s, 0 ] );
        my $l_scan_loop = $builder->new_label();
        my $l_scan_done = $builder->new_label();
        $builder->emit_label($l_scan_loop);
        my $idx = $builder->emit( 'local_load', 'i64', [$idx_s] );
        $builder->emit_cond_br( $builder->emit( 'cmp_ge', 'Int', [ $idx, $rlt_sz ] ), $l_scan_done, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        my $idx_offset = $builder->emit( 'mul',           'i64', [ $idx,        32 ] );
        my $entry_addr = $builder->emit( 'add',           'ptr', [ $rlt_ptr,    $idx_offset ] );
        my $entry_off  = $builder->emit( 'load_mem_disp', 'i64', [ $entry_addr, 0 ] );
        my $entry_line = $builder->emit( 'load_mem_disp', 'i64', [ $entry_addr, 8 ] );
        my $entry_col  = $builder->emit( 'load_mem_disp', 'i64', [ $entry_addr, 16 ] );
        my $entry_file = $builder->emit( 'load_mem_disp', 'i64', [ $entry_addr, 24 ] );
        my $l_match    = $builder->new_label();
        my $l_no_match = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_le', 'Int', [ $entry_off, $t_rva ] ), $l_match, $l_no_match );
        $builder->emit_label($l_match);
        $builder->emit( 'local_store', 'void', [ $best_line_s, $entry_line ] );
        $builder->emit( 'local_store', 'void', [ $best_col_s,  $entry_col ] );
        $builder->emit( 'local_store', 'void', [ $best_file_s, $entry_file ] );
        $builder->emit( 'local_store', 'void', [ $idx_s,       $builder->emit( 'add', 'i64', [ $idx, 1 ] ) ] );
        $builder->emit_jump($l_scan_loop);
        $builder->emit_label($l_no_match);
        $builder->emit_jump($l_scan_done);
        $builder->emit_label($l_scan_done);
        my $best_line    = $builder->emit( 'local_load', 'i64', [$best_line_s] );
        my $best_col     = $builder->emit( 'local_load', 'i64', [$best_col_s] );
        my $best_file    = $builder->emit( 'local_load', 'i64', [$best_file_s] );
        my $l_print_loc  = $builder->new_label();
        my $l_skip_print = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_gt', 'Int', [ $best_line, 0 ] ), $l_print_loc, $l_skip_print );
        $builder->emit_label($l_print_loc);
        my $fn_addr_s      = $driver->alloc_local_slot();
        my $l_custom_file  = $builder->new_label();
        my $l_default_file = $builder->new_label();
        my $l_file_done    = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_ne', 'Int', [ $best_file, 0 ] ), $l_custom_file, $l_default_file );
        $builder->emit_label($l_custom_file);
        $builder->emit( 'local_store', 'void', [ $fn_addr_s, $builder->emit( 'add', 'ptr', [ $data_base, $best_file ] ) ] );
        $builder->emit_jump($l_file_done);
        $builder->emit_label($l_default_file);
        $builder->emit( 'local_store', 'void', [ $fn_addr_s, $builder->emit( 'load_data_addr', 'ptr', [$fn_rva] ) ] );
        $builder->emit_jump($l_file_done);
        $builder->emit_label($l_file_done);
        my $fn_addr       = $builder->emit( 'local_load', 'ptr', [$fn_addr_s] );
        my $l_first_frame = $builder->new_label();
        my $l_other_frame = $builder->new_label();
        my $l_at_done     = $builder->new_label();
        my $is_first      = $builder->emit( 'cmp_eq', 'Int', [ $builder->emit( 'local_load', 'i64', [$trace_depth_s] ), 0 ] );
        my $has_msg       = $builder->emit( 'cmp_ne', 'Int', [ $builder->emit( 'local_load', 'ptr', [$msg_slot] ), 0 ] );
        $builder->emit_cond_br( $builder->emit( 'and', 'i64', [ $is_first, $has_msg ] ), $l_first_frame, $l_other_frame );
        $builder->emit_label($l_first_frame);
        $builder->emit( 'intrinsic_print', 'void', [ $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string(" at ") ] ) ] );
        $builder->emit_jump($l_at_done);
        $builder->emit_label($l_other_frame);
        $builder->emit( 'intrinsic_print', 'void', [ $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string("  at ") ] ) ] );
        $builder->emit_label($l_at_done);
        $builder->emit( 'intrinsic_print', 'void', [$fn_addr] );
        $builder->emit( 'intrinsic_print', 'void', [ $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string(" line ") ] ) ] );
        $builder->emit( 'call_func', 'void',
            [ 'M_print_int', $builder->emit( 'or', 'i64', [ $builder->emit( 'shl', 'i64', [ $best_line, 1 ] ), 1 ] ) ] );
        $builder->emit( 'intrinsic_print', 'void', [ $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string(", col ") ] ) ] );
        $builder->emit( 'call_func', 'void',
            [ 'M_print_int', $builder->emit( 'or', 'i64', [ $builder->emit( 'shl', 'i64', [ $best_col, 1 ] ), 1 ] ) ] );
        $builder->emit( 'intrinsic_print', 'void', [ $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string("\n") ] ) ] );
        $builder->emit_label($l_skip_print);
        $builder->emit( 'local_store', 'void', [ $trace_bp_s,    $t_prev ] );
        $builder->emit( 'local_store', 'void', [ $trace_depth_s, $builder->emit( 'add', 'i64', [ $t_depth, 1 ] ) ] );
        $builder->emit_jump($l_trace_loop);
        $builder->emit_label($l_trace_done);

        # --- End Unhandled Exception Stack-Trace Backtrace ---
        $builder->emit( 'intrinsic_exit', 'void', [ $builder->emit( 'constant', 'i64', [255] ) ] );
        $builder->emit_label($l_search);
        my $rip       = $builder->emit( 'load_mem_disp', 'ptr', [ $curr_bp, $driver->rip_offset() ] );
        my $prev_bp   = $builder->emit( 'load_mem_disp', 'ptr', [ $curr_bp, $driver->prev_bp_offset() ] );
        my $rva       = $builder->emit( 'sub',           'i64', [ $builder->emit( 'sub', 'i64', [ $rip, $text_base ] ), 1 ] );
        my $num_funcs = $builder->emit( 'load_mem_disp', 'i64', [ $extab_ptr, 0 ] );
        my $fi_s      = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $fi_s, 0 ] );
        my $f_ptr_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $f_ptr_s, $builder->emit( 'add', 'ptr', [ $extab_ptr, 8 ] ) ] );
        my $l_f_loop = $builder->new_label();
        $builder->emit_label($l_f_loop);
        my $fi       = $builder->emit( 'local_load', 'i64', [$fi_s] );
        my $l_f_done = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_ge', 'Int', [ $fi, $num_funcs ] ), $l_f_done, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        my $f_ptr         = $builder->emit( 'local_load',    'ptr', [$f_ptr_s] );
        my $f_start       = $builder->emit( 'load_mem_disp', 'i64', [ $f_ptr, 0 ] );
        my $f_end         = $builder->emit( 'load_mem_disp', 'i64', [ $f_ptr, 8 ] );
        my $num_tries     = $builder->emit( 'load_mem_disp', 'i64', [ $f_ptr, 16 ] );
        my $l_check_tries = $builder->new_label();
        my $l_f_inc       = $builder->new_label();
        my $in_f          = $builder->emit( 'and', 'i64',
            [ $builder->emit( 'cmp_ge', 'Int', [ $rva, $f_start ] ), $builder->emit( 'cmp_lt', 'Int', [ $rva, $f_end ] ) ] );
        $builder->emit_cond_br( $in_f, $l_check_tries, $l_f_inc );
        $builder->emit_label($l_check_tries);
        my $ti_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $ti_s, 0 ] );
        my $t_ptr_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $t_ptr_s, $builder->emit( 'add', 'ptr', [ $f_ptr, 24 ] ) ] );
        my $l_t_loop = $builder->new_label();
        $builder->emit_label($l_t_loop);
        my $ti = $builder->emit( 'local_load', 'i64', [$ti_s] );
        $builder->emit_cond_br( $builder->emit( 'cmp_ge', 'Int', [ $ti, $num_tries ] ), $l_f_done, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        my $t_ptr     = $builder->emit( 'local_load',    'ptr', [$t_ptr_s] );
        my $t_start   = $builder->emit( 'load_mem_disp', 'i64', [ $t_ptr, 0 ] );
        my $t_end     = $builder->emit( 'load_mem_disp', 'i64', [ $t_ptr, 8 ] );
        my $l_t_match = $builder->new_label();
        my $l_t_inc   = $builder->new_label();
        my $in_t      = $builder->emit( 'and', 'i64',
            [ $builder->emit( 'cmp_ge', 'Int', [ $rva, $t_start ] ), $builder->emit( 'cmp_lt', 'Int', [ $rva, $t_end ] ) ] );
        $builder->emit_cond_br( $in_t, $l_t_match, $l_t_inc );
        $builder->emit_label($l_t_match);
        my $catch_pc = $builder->emit( 'load_mem_disp', 'i64', [ $t_ptr, 16 ] );
        $builder->emit( 'intrinsic_restore_context', 'void', [ $prev_bp, $builder->emit( 'add', 'ptr', [ $text_base, $catch_pc ] ), $curr_bp ] );
        $builder->emit_label($l_t_inc);
        $builder->emit( 'local_store', 'void', [ $ti_s,    $builder->emit( 'add', 'i64', [ $ti,    1 ] ) ] );
        $builder->emit( 'local_store', 'void', [ $t_ptr_s, $builder->emit( 'add', 'ptr', [ $t_ptr, 32 ] ) ] );
        $builder->emit_jump($l_t_loop);
        $builder->emit_label($l_f_inc);
        $builder->emit( 'local_store', 'void', [ $fi_s, $builder->emit( 'add', 'i64', [ $fi, 1 ] ) ] );
        my $f_skip = $builder->emit( 'add', 'i64', [ 24, $builder->emit( 'mul', 'i64', [ $num_tries, 32 ] ) ] );
        $builder->emit( 'local_store', 'void', [ $f_ptr_s, $builder->emit( 'add', 'ptr', [ $f_ptr, $f_skip ] ) ] );
        $builder->emit_jump($l_f_loop);
        $builder->emit_label($l_f_done);
        $builder->emit( 'local_store', 'void', [ $bp_slot,        $prev_bp ] );
        $builder->emit( 'local_store', 'void', [ $search_depth_s, $builder->emit( 'add', 'i64', [ $s_depth, 1 ] ) ] );
        $builder->emit_jump($l_frame_loop);
        $builder->emit( 'leave_func', 'void', [] );
    }

    method inject_runtime_gc_mark_obj() {
        $driver->reset_locals();
        $builder->emit_label('M_gc_mark_obj');
        $builder->emit( 'enter_func', 'void', [] );
        my $root_slot = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $root_slot, $builder->emit( 'get_arg', 'ptr', [0] ) ] );
        my $ms_ptr = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('mark_stack_ptr') ] );
        $builder->emit( 'store_mem_disp', 'void', [ $ms_ptr, 0, $builder->emit( 'local_load', 'ptr', [$root_slot] ) ] );
        $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('mark_stack_ptr'), $builder->emit( 'add', 'ptr', [ $ms_ptr, 8 ] ) ] );
        my $l_mark_start = $builder->new_label();
        my $l_mark_done  = $builder->new_label();
        $builder->emit_label($l_mark_start);
        my $curr_ms           = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('mark_stack_ptr') ] );
        my $ms_base           = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('mark_stack_base') ] );
        my $l_stack_not_empty = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_le', 'Int', [ $curr_ms, $ms_base ] ), $l_mark_done, $l_stack_not_empty );
        $builder->emit_label($l_stack_not_empty);
        my $pop_ptr = $builder->emit( 'sub', 'ptr', [ $curr_ms, 8 ] );
        $builder->emit( 'local_store', 'void', [ $root_slot, $builder->emit( 'load_mem_disp', 'ptr', [ $pop_ptr, 0 ] ) ] );
        $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('mark_stack_ptr'), $pop_ptr ] );
        my $l_next     = $l_mark_start;
        my $l_not_null = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $builder->emit( 'local_load', 'ptr', [$root_slot] ), 0 ] ), $l_next, $l_not_null );
        $builder->emit_label($l_not_null);
        my $l_not_smi = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'and', 'i64', [ $builder->emit( 'local_load', 'ptr', [$root_slot] ), 1 ] ), $l_next, $l_not_smi );
        $builder->emit_label($l_not_smi);

        # --- CRITICAL FIX: GC HEAP RANGE CHECK ---
        # Extract 64-bit block address boundary
        my $block = $builder->emit( 'and', 'i64',
            [ $builder->emit( 'local_load', 'ptr', [$root_slot] ), $builder->emit( 'constant', 'i64', [ hex("FFFFFFFFFFFF0000") ] ) ] );

        # Read unique heap signature at [block + 8] to verify this is a dynamic heap pointer
        my $sig          = $builder->emit( 'load_mem_disp', 'i64', [ $block, 8 ] );
        my $l_valid_heap = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $sig, $builder->emit( 'constant', 'i64', [0x424b4e4845415036] ) ] ),
            $l_valid_heap, $l_next );
        $builder->emit_label($l_valid_heap);
        my $off
            = $builder->emit( 'sub', 'i64', [ $builder->emit( 'sub', 'i64', [ $builder->emit( 'local_load', 'ptr', [$root_slot] ), 8 ] ), $block ] );
        my $hdr_slot = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'i64',
            [ $hdr_slot, $builder->emit( 'load_mem_disp', 'i64', [ $builder->emit( 'local_load', 'ptr', [$root_slot] ), -8 ] ) ] );
        my $cyc = $builder->emit( 'load_iso_disp', 'i64', [ $driver->iso_offset('gc_cycle') ] );
        my $obj_cyc
            = $builder->emit( 'and', 'i64', [ $builder->emit( 'shr', 'i64', [ $builder->emit( 'local_load', 'i64', [$hdr_slot] ), 40 ] ), 0xFF ] );
        my $l_not_marked = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $obj_cyc, $cyc ] ), $l_next, $l_not_marked );
        $builder->emit_label($l_not_marked);
        my $start_line = $builder->emit( 'shr', 'i64', [ $off, 7 ] );
        my $obj_sz     = $builder->emit( 'and', 'i64',
            [ $builder->emit( 'local_load', 'i64', [$hdr_slot] ), $builder->emit( 'constant', 'i64', [ hex("FFFFFFFFFF") ] ) ] );
        my $off_mod_128 = $builder->emit( 'and', 'i64', [ $off,    127 ] );
        my $span        = $builder->emit( 'add', 'i64', [ $obj_sz, $off_mod_128 ] );
        my $num_lines   = $builder->emit( 'div', 'i64', [ $builder->emit( 'add', 'i64', [ $span, 127 ] ), 128 ] );
        my $ml_i        = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $ml_i, 0 ] );
        my $l_ml = $builder->new_label();
        my $l_md = $builder->new_label();
        $builder->emit_label($l_ml);
        my $curr_ml   = $builder->emit( 'local_load', 'i64', [$ml_i] );
        my $l_ml_body = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_lt', 'Int', [ $curr_ml, $num_lines ] ), $l_ml_body, $l_md );
        $builder->emit_label($l_ml_body);
        $builder->emit( 'store_mem_byte', 'void',
            [ $block, $builder->emit( 'add', 'i64', [ $builder->emit( 'add', 'i64', [ $start_line, $curr_ml ] ), 16 ] ), 1 ] );
        $builder->emit( 'local_store', 'void', [ $ml_i, $builder->emit( 'add', 'i64', [ $curr_ml, 1 ] ) ] );
        $builder->emit_jump($l_ml);
        $builder->emit_label($l_md);
        my $clean_hdr = $builder->emit( 'and', 'i64',
            [ $builder->emit( 'local_load', 'i64', [$hdr_slot] ), $builder->emit( 'constant', 'i64', [ ~( 0xFF << 40 ) ] ) ] );
        my $marked_hdr = $builder->emit( 'or', 'i64', [ $clean_hdr, $builder->emit( 'shl', 'i64', [ $cyc, 40 ] ) ] );
        $builder->emit( 'store_mem_disp', 'void', [ $builder->emit( 'local_load', 'ptr', [$root_slot] ), -8, $marked_hdr ] );
        my $l_not_leaf = $builder->new_label();
        $builder->emit_cond_br(
            $builder->emit( 'cmp_eq', 'Int', [ $builder->emit( 'shr', 'i64', [ $builder->emit( 'local_load', 'i64', [$hdr_slot] ), 62 ] ), 3 ] ),
            $l_next, $l_not_leaf );
        $builder->emit_label($l_not_leaf);
        my $first      = $builder->emit( 'load_mem_disp', 'i64', [ $builder->emit( 'local_load', 'ptr', [$root_slot] ), 0 ] );
        my $l_is_obj   = $builder->new_label();
        my $l_is_array = $builder->new_label();

        # --- NEW TAGGING LOGIC ---
        my $tag_bits = $builder->emit( 'and', 'i64', [ $first, 3 ] );
        $builder->emit_cond_br( $builder->emit( 'cmp_ne', 'Int', [ $tag_bits, 0 ] ), $l_is_array, $l_is_obj );
        $builder->emit_label($l_is_array);
        my $count = $builder->emit( 'shr', 'i64', [ $first, 2 ] );
        my $ai_s  = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $ai_s, 0 ] );
        my $l_al = $builder->new_label();
        $builder->emit_label($l_al);
        my $ai        = $builder->emit( 'local_load', 'i64', [$ai_s] );
        my $l_al_body = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_ge', 'Int', [ $ai, $count ] ), $l_mark_start, $l_al_body );
        $builder->emit_label($l_al_body);
        my $el_ptr = $builder->emit(
            'add', 'ptr',
            [   $builder->emit( 'local_load', 'ptr', [$root_slot] ), $builder->emit( 'add', 'i64', [ $builder->emit( 'mul', 'i64', [ $ai, 8 ] ), 8 ] )
            ]
        );
        my $el    = $builder->emit( 'load_mem_disp', 'ptr', [ $el_ptr, 0 ] );
        my $p_ptr = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('mark_stack_ptr') ] );
        $builder->emit( 'store_mem_disp', 'void', [ $p_ptr, 0, $el ] );
        $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('mark_stack_ptr'), $builder->emit( 'add', 'ptr', [ $p_ptr, 8 ] ) ] );
        $builder->emit( 'local_store',    'void', [ $ai_s, $builder->emit( 'add', 'i64', [ $ai, 1 ] ) ] );
        $builder->emit_jump($l_al);
        $builder->emit_label($l_is_obj);
        my $p_ct = $builder->emit( 'load_mem_disp', 'i64', [ $first, -8 ] );
        my $pi_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $pi_s, 0 ] );
        my $l_ol = $builder->new_label();
        $builder->emit_label($l_ol);
        my $pi        = $builder->emit( 'local_load', 'i64', [$pi_s] );
        my $l_ol_body = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_ge', 'Int', [ $pi, $p_ct ] ), $l_mark_start, $l_ol_body );
        $builder->emit_label($l_ol_body);
        my $voff_ptr = $builder->emit( 'sub', 'ptr', [ $first, $builder->emit( 'add', 'i64', [ $builder->emit( 'mul', 'i64', [ $pi, 8 ] ), 16 ] ) ] );
        my $voff     = $builder->emit( 'load_mem_disp', 'i64', [ $voff_ptr, 0 ] );
        my $ch       = $builder->emit( 'load_mem_disp', 'ptr',
            [ $builder->emit( 'add', 'ptr', [ $builder->emit( 'local_load', 'ptr', [$root_slot] ), $voff ] ), 0 ] );
        my $o_ptr = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('mark_stack_ptr') ] );
        $builder->emit( 'store_mem_disp', 'void', [ $o_ptr, 0, $ch ] );
        $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('mark_stack_ptr'), $builder->emit( 'add', 'ptr', [ $o_ptr, 8 ] ) ] );
        $builder->emit( 'local_store',    'void', [ $pi_s, $builder->emit( 'add', 'i64', [ $pi, 1 ] ) ] );
        $builder->emit_jump($l_ol);
        $builder->emit_label($l_mark_done);
        $builder->emit( 'leave_func', 'void', [0] );
    }

    method inject_runtime_gc_sweep() {
        $driver->reset_locals();
        $builder->emit_label('M_gc_sweep');
        $builder->emit( 'enter_func', 'void', [] );
        my $bh_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $bh_s, $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('heap_base') ] ) ] );
        my $l_bl = $builder->new_label();
        my $l_bd = $builder->new_label();
        $builder->emit_label($l_bl);
        my $cbh       = $builder->emit( 'local_load', 'ptr', [$bh_s] );
        my $l_bl_body = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $cbh, 0 ] ), $l_bd, $l_bl_body );
        $builder->emit_label($l_bl_body);
        my $idx_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $idx_s, 8 ] );
        my $l_ll = $builder->new_label();
        my $l_ld = $builder->new_label();
        $builder->emit_label($l_ll);
        my $idx       = $builder->emit( 'local_load', 'i64', [$idx_s] );
        my $l_ll_body = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_ge', 'Int', [ $idx, 512 ] ), $l_ld, $l_ll_body );
        $builder->emit_label($l_ll_body);
        my $mk        = $builder->emit( 'load_mem_byte', 'Int', [ $cbh, $builder->emit( 'add', 'i64', [ $idx, 16 ] ) ] );
        my $l_hole    = $builder->new_label();
        my $l_no_hole = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $mk, 0 ] ), $l_hole, $l_no_hole );
        $builder->emit_label($l_hole);
        my $hp = $builder->emit( 'add', 'ptr', [ $cbh, $builder->emit( 'mul', 'i64', [ $idx, 128 ] ) ] );
        $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('heap_ptr'), $hp ] );
        my $eidx_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $eidx_s, $builder->emit( 'add', 'i64', [ $idx, 1 ] ) ] );
        my $l_el = $builder->new_label();
        my $l_ed = $builder->new_label();
        $builder->emit_label($l_el);
        my $eidx      = $builder->emit( 'local_load', 'i64', [$eidx_s] );
        my $l_el_body = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_ge', 'Int', [ $eidx, 512 ] ), $l_ed, $l_el_body );
        $builder->emit_label($l_el_body);
        my $emk       = $builder->emit( 'load_mem_byte', 'Int', [ $cbh, $builder->emit( 'add', 'i64', [ $eidx, 16 ] ) ] );
        my $l_el_next = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_ne', 'Int', [ $emk, 0 ] ), $l_ed, $l_el_next );
        $builder->emit_label($l_el_next);
        $builder->emit( 'local_store', 'void', [ $eidx_s, $builder->emit( 'add', 'i64', [ $eidx, 1 ] ) ] );
        $builder->emit_jump($l_el);
        $builder->emit_label($l_ed);
        my $final_idx = $builder->emit( 'local_load', 'i64', [$eidx_s] );
        $builder->emit( 'store_iso_disp', 'void',
            [ $driver->iso_offset('heap_limit'), $builder->emit( 'add', 'ptr', [ $cbh, $builder->emit( 'mul', 'i64', [ $final_idx, 128 ] ) ] ) ] );
        $builder->emit( 'leave_func', 'void', [0] );
        $builder->emit_label($l_no_hole);
        $builder->emit( 'local_store', 'void', [ $idx_s, $builder->emit( 'add', 'i64', [ $idx, 1 ] ) ] );
        $builder->emit_jump($l_ll);
        $builder->emit_label($l_ld);
        $builder->emit( 'local_store', 'void', [ $bh_s, $builder->emit( 'load_mem_disp', 'ptr', [ $cbh, 0 ] ) ] );
        $builder->emit_jump($l_bl);
        $builder->emit_label($l_bd);
        $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('heap_ptr'),   0 ] );
        $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('heap_limit'), 0 ] );
        $builder->emit( 'leave_func',     'void', [0] );
    }

    # --- Major Generation Evacuating Collector ---
    method inject_runtime_gc_collect() {
        $driver->reset_locals();
        $builder->emit_label('M_gc_collect');
        $builder->emit( 'enter_func', 'void', [] );

        # Increment GC cycle (Used by Minor GC scanning)
        $builder->emit(
            'store_iso_disp',
            'void',
            [   $driver->iso_offset('gc_cycle'),
                $builder->emit(
                    'and', 'i64',
                    [   $builder->emit( 'add', 'i64', [ $builder->emit( 'load_iso_disp', 'i64', [ $driver->iso_offset('gc_cycle') ] ), 1 ] ),
                        0x1FFFFF
                    ]
                )
            ]
        );
        my $to_base  = $builder->emit( 'load_iso_disp', 'ptr', [88] );    # tospace_base
        my $to_limit = $builder->emit( 'load_iso_disp', 'ptr', [96] );    # tospace_limit

        # 104 is repurposed as tospace_ptr during evacuation
        $builder->emit( 'store_iso_disp', 'void', [ 104, $builder->emit( 'add', 'ptr', [ $to_base, 1024 ] ) ] );

        # Scan exact roots (Shadow Stack & Globals only, NO physical stack)
        $self->_emit_root_scan('M_evacuate_major');

        # Cheney scan the ToSpace to resolve promoted pointers
        my $scan_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $scan_s, $builder->emit( 'add', 'ptr', [ $to_base, 1032 ] ) ] );
        $self->_emit_cheney_scan( $scan_s, sub { $builder->emit( 'add', 'ptr', [ $builder->emit( 'load_iso_disp', 'ptr', [104] ), 8 ] ) },
            'M_evacuate_major' );
        my $from_base  = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('heap_base') ] );
        my $from_limit = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('heap_limit') ] );

        # Swap Spaces
        $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('heap_base'),  $to_base ] );
        $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('heap_ptr'),   $builder->emit( 'load_iso_disp', 'ptr', [104] ) ] );
        $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('heap_limit'), $to_limit ] );
        $builder->emit( 'store_iso_disp', 'void', [ 88, $from_base ] );
        $builder->emit( 'store_iso_disp', 'void', [ 96, $from_limit ] );

        # Instantly reclaim the entire nursery by resetting the bump pointer
        $builder->emit( 'store_iso_disp', 'void',
            [ $driver->iso_offset('nursery_ptr'), $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('nursery_base') ] ) ] );
        $builder->emit( 'leave_func', 'void', [] );
    }

    # --- Helper for emitting Root Scans ---
    method _emit_root_scan($evac_fn) {

        # Fibers
        my $fs_slot = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $fs_slot, $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('fiber_head') ] ) ] );
        my $l_fl = $builder->new_label();
        my $l_fd = $builder->new_label();
        $builder->emit_label($l_fl);
        my $fib = $builder->emit( 'local_load', 'ptr', [$fs_slot] );
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $fib, 0 ] ), $l_fd, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        my $promoted_fib = $builder->emit( 'call_func', 'ptr', [ $evac_fn, $fib ] );
        my $l_not_head   = $builder->new_label();
        my $is_head = $builder->emit( 'cmp_eq', 'Int', [ $fib, $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('fiber_head') ] ) ] );
        $builder->emit_cond_br( $is_head, $builder->new_label(), $l_not_head );
        $builder->emit_label( $builder->last_instruction->{true_l} );
        $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('fiber_head'), $promoted_fib ] );
        $builder->emit_label($l_not_head);
        $fib = $promoted_fib;

        # Exact Root Scan: Shadow Stack (Only tracks guaranteed pointers)
        my $sh_base     = $builder->emit( 'load_mem_disp', 'ptr', [ $fib, 24 ] );
        my $sh_ptr_slot = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $sh_ptr_slot, $builder->emit( 'load_mem_disp', 'ptr', [ $fib, 32 ] ) ] );
        my $l_sh_l = $builder->new_label();
        my $l_sh_d = $builder->new_label();
        $builder->emit_label($l_sh_l);
        my $csh = $builder->emit( 'local_load', 'ptr', [$sh_ptr_slot] );
        $builder->emit_cond_br( $builder->emit( 'cmp_le', 'Int', [ $csh, $sh_base ] ), $l_sh_d, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        my $sh_prev     = $builder->emit( 'sub',           'ptr', [ $csh,     8 ] );
        my $sh_val      = $builder->emit( 'load_mem_disp', 'ptr', [ $sh_prev, 0 ] );
        my $promoted_sh = $builder->emit( 'call_func',     'ptr', [ $evac_fn, $sh_val ] );
        $builder->emit( 'store_mem_disp', 'void', [ $sh_prev, 0, $promoted_sh ] );
        $builder->emit( 'local_store', 'void', [ $sh_ptr_slot, $sh_prev ] );
        $builder->emit_jump($l_sh_l);
        $builder->emit_label($l_sh_d);

        # Exception object
        my $exc          = $builder->emit( 'load_mem_disp', 'ptr', [ $fib,     64 ] );
        my $promoted_exc = $builder->emit( 'call_func',     'ptr', [ $evac_fn, $exc ] );
        $builder->emit( 'store_mem_disp', 'void', [ $fib, 64, $promoted_exc ] );

        # Next fiber
        my $nxt      = $builder->emit( 'load_mem_disp', 'ptr', [ $fib, 48 ] );
        my $l_no_nxt = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $nxt, 0 ] ), $l_no_nxt, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        my $promoted_nxt = $builder->emit( 'call_func', 'ptr', [ $evac_fn, $nxt ] );
        $builder->emit( 'store_mem_disp', 'void', [ $fib, 48, $promoted_nxt ] );
        $builder->emit_label($l_no_nxt);
        $builder->emit( 'local_store', 'void', [ $fs_slot, $nxt ] );
        $builder->emit_jump($l_fl);
        $builder->emit_label($l_fd);

        # GC State Block
        my $stm = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('state_ptr') ] );
        for ( my $i = 0; $i < $state_count; $i++ ) {
            my $addr     = $builder->emit( 'add',           'ptr', [ $stm,     4096 + ( $i * 8 ) ] );
            my $val      = $builder->emit( 'load_mem_disp', 'ptr', [ $addr,    0 ] );
            my $promoted = $builder->emit( 'call_func',     'ptr', [ $evac_fn, $val ] );
            $builder->emit( 'store_mem_disp', 'void', [ $addr, 0, $promoted ] );
        }

        # Globals (Include current_fcb and System Handles)
        for my $off ( 24, 176, 184, 192, 200, 208, 216, 224, 240 ) {
            my $val      = $builder->emit( 'load_iso_disp', 'ptr', [$off] );
            my $promoted = $builder->emit( 'call_func',     'ptr', [ $evac_fn, $val ] );
            $builder->emit( 'store_iso_disp', 'void', [ $off, $promoted ] );
        }
        for ( my $off = 256; $off < $our_var_next_offset; $off += 8 ) {
            my $val      = $builder->emit( 'load_iso_disp', 'ptr', [$off] );
            my $promoted = $builder->emit( 'call_func',     'ptr', [ $evac_fn, $val ] );
            $builder->emit( 'store_iso_disp', 'void', [ $off, $promoted ] );
        }
    }

    # --- Helper for emitting Cheney Linear Scanning ---
    method _emit_cheney_scan( $scan_ptr_s, $limit_val_gen, $evac_fn ) {
        my $l_cl = $builder->new_label();
        my $l_cd = $builder->new_label();
        $builder->emit_label($l_cl);
        my $sp        = $builder->emit( 'local_load', 'ptr', [$scan_ptr_s] );
        my $limit_val = $limit_val_gen->();
        $builder->emit_cond_br( $builder->emit( 'cmp_ge', 'Int', [ $sp, $limit_val ] ), $l_cd, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        my $hdr        = $builder->emit( 'load_mem_disp', 'i64', [ $sp,  -8 ] );
        my $sz         = $builder->emit( 'and',           'i64', [ $hdr, $builder->emit( 'constant', 'i64', [ hex("FFFFFFFFFF") ] ) ] );
        my $is_leaf    = $builder->emit( 'cmp_eq',        'Int', [ $builder->emit( 'shr', 'i64', [ $hdr, 62 ] ), 3 ] );
        my $l_next_obj = $builder->new_label();
        $builder->emit_cond_br( $is_leaf, $l_next_obj, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        my $first    = $builder->emit( 'load_mem_disp', 'i64', [ $sp,    0 ] );
        my $tag      = $builder->emit( 'and',           'i64', [ $first, 3 ] );
        my $l_is_arr = $builder->new_label();
        my $l_is_obj = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_ne', 'Int', [ $tag, 0 ] ), $l_is_arr, $l_is_obj );
        $builder->emit_label($l_is_arr);
        my $count = $builder->emit( 'shr', 'i64', [ $first, 2 ] );
        my $i_s   = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $i_s, 0 ] );
        my $l_al = $builder->new_label();
        my $l_ad = $builder->new_label();
        $builder->emit_label($l_al);
        my $i = $builder->emit( 'local_load', 'i64', [$i_s] );
        $builder->emit_cond_br( $builder->emit( 'cmp_ge', 'Int', [ $i, $count ] ), $l_ad, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        my $el_p     = $builder->emit( 'add', 'ptr', [ $sp, $builder->emit( 'add', 'i64', [ 8, $builder->emit( 'mul', 'i64', [ $i, 8 ] ) ] ) ] );
        my $val      = $builder->emit( 'load_mem_disp', 'ptr', [ $el_p,    0 ] );
        my $promoted = $builder->emit( 'call_func',     'ptr', [ $evac_fn, $val ] );
        $builder->emit( 'store_mem_disp', 'void', [ $el_p, 0, $promoted ] );
        $builder->emit( 'local_store', 'void', [ $i_s, $builder->emit( 'add', 'i64', [ $i, 1 ] ) ] );
        $builder->emit_jump($l_al);
        $builder->emit_label($l_ad);
        $builder->emit_jump($l_next_obj);
        $builder->emit_label($l_is_obj);
        my $p_ct = $builder->emit( 'load_mem_disp', 'i64', [ $first, -8 ] );
        $builder->emit( 'local_store', 'void', [ $i_s, 0 ] );
        my $l_ol = $builder->new_label();
        my $l_od = $builder->new_label();
        $builder->emit_label($l_ol);
        $i = $builder->emit( 'local_load', 'i64', [$i_s] );
        $builder->emit_cond_br( $builder->emit( 'cmp_ge', 'Int', [ $i, $p_ct ] ), $l_od, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        my $voff = $builder->emit( 'load_mem_disp', 'i64',
            [ $builder->emit( 'sub', 'ptr', [ $first, $builder->emit( 'add', 'i64', [ 16, $builder->emit( 'mul', 'i64', [ $i, 8 ] ) ] ) ] ), 0 ] );
        my $field_p = $builder->emit( 'add', 'ptr', [ $sp, $voff ] );
        $val      = $builder->emit( 'load_mem_disp', 'ptr', [ $field_p, 0 ] );
        $promoted = $builder->emit( 'call_func',     'ptr', [ $evac_fn, $val ] );
        $builder->emit( 'store_mem_disp', 'void', [ $field_p, 0, $promoted ] );
        $builder->emit( 'local_store', 'void', [ $i_s, $builder->emit( 'add', 'i64', [ $i, 1 ] ) ] );
        $builder->emit_jump($l_ol);
        $builder->emit_label($l_od);
        $builder->emit_jump($l_next_obj);
        $builder->emit_label($l_next_obj);
        $builder->emit( 'local_store', 'void', [ $scan_ptr_s, $builder->emit( 'add', 'ptr', [ $sp, $sz ] ) ] );
        $builder->emit_jump($l_cl);
        $builder->emit_label($l_cd);
    }

    # --- Fast Path & Fallback Allocation ---
    method inject_runtime_gc_alloc() {
        $driver->reset_locals();
        $builder->emit_label('M_gc_alloc');
        $builder->emit( 'enter_func', 'void', [] );
        my $psz    = $builder->emit( 'get_arg', 'i64', [0] );
        my $sz_raw = $builder->emit(
            'and', 'i64',
            [   $builder->emit(
                    'add', 'i64', [ $builder->emit( 'and', 'i64', [ $psz, $builder->emit( 'constant', 'i64', [ hex("FFFFFFFFFF") ] ) ] ), 15 ]
                ),
                $builder->emit( 'constant', 'i64', [-8] )
            ]
        );
        my $sz_slot = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $sz_slot, $sz_raw ] );

        # FIX: Use FFFF mask to preserve RC (48..60), Special (61) and Leaf Flags (62..63)
        my $fhdr = $builder->emit( 'or', 'i64',
            [ $sz_raw, $builder->emit( 'and', 'i64', [ $psz, $builder->emit( 'constant', 'i64', [ hex("FFFF000000000000") ] ) ] ) ] );
        my $fhdr_slot = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $fhdr_slot, $fhdr ] );
        my $sz            = $builder->emit( 'local_load', 'i64', [$sz_slot] );
        my $l_try_tenured = $builder->new_label();

        # Massive objects bypass nursery
        $builder->emit_cond_br( $builder->emit( 'cmp_gt', 'Int', [ $sz, 32768 ] ), $l_try_tenured, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        my $n_ptr           = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('nursery_ptr') ] );
        my $n_limit         = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('nursery_limit') ] );
        my $n_next          = $builder->emit( 'add',           'ptr', [ $n_ptr, $sz ] );
        my $l_nursery_alloc = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_le', 'Int', [ $n_next, $n_limit ] ), $l_nursery_alloc, $l_try_tenured );
        $builder->emit_label($l_nursery_alloc);
        $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('nursery_ptr'), $n_next ] );
        $builder->emit( 'store_mem_disp', 'void', [ $n_ptr, 0, $builder->emit( 'local_load', 'i64', [$fhdr_slot] ) ] );
        my $obj_ptr = $builder->emit( 'add', 'ptr', [ $n_ptr, 8 ] );
        my $zp_s    = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $zp_s, $obj_ptr ] );
        my $l_zl = $builder->new_label();
        my $l_ze = $builder->new_label();
        $builder->emit_label($l_zl);
        my $zp = $builder->emit( 'local_load', 'ptr', [$zp_s] );
        $builder->emit_cond_br( $builder->emit( 'cmp_lt', 'Int', [ $zp, $n_next ] ), $builder->new_label(), $l_ze );
        $builder->emit_label( $builder->last_instruction->{true_l} );
        $builder->emit( 'store_mem_disp', 'void', [ $zp, 0, 0 ] );
        $builder->emit( 'local_store', 'void', [ $zp_s, $builder->emit( 'add', 'ptr', [ $zp, 8 ] ) ] );
        $builder->emit_jump($l_zl);
        $builder->emit_label($l_ze);
        $builder->emit( 'leave_func', 'ptr', [$obj_ptr] );
        $builder->emit_label($l_try_tenured);
        $builder->emit( 'leave_func', 'ptr',
            [ $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc_tenured', $psz, $builder->emit( 'constant', 'i64', [1] ) ] ) ] );
    }

    method inject_runtime_gc_alloc_tenured() {
        $driver->reset_locals();
        $builder->emit_label('M_gc_alloc_tenured');
        $builder->emit( 'enter_func', 'void', [] );
        my $psz      = $builder->emit( 'get_arg', 'i64', [0] );
        my $allow_gc = $builder->emit( 'get_arg', 'i64', [1] );
        my $sz       = $builder->emit(
            'and', 'i64',
            [   $builder->emit(
                    'add', 'i64', [ $builder->emit( 'and', 'i64', [ $psz, $builder->emit( 'constant', 'i64', [ hex("FFFFFFFFFF") ] ) ] ), 15 ]
                ),
                $builder->emit( 'constant', 'i64', [-8] )
            ]
        );

        # FIX: DFFF mask to preserve RC
        my $fhdr = $builder->emit( 'or', 'i64',
            [ $sz, $builder->emit( 'and', 'i64', [ $psz, $builder->emit( 'constant', 'i64', [ hex("FFFF000000000000") ] ) ] ) ] );
        my $l_alloc = $builder->new_label();
        my $l_gc    = $builder->new_label();
        my $hp      = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('heap_ptr') ] );
        my $hl      = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('heap_limit') ] );
        $builder->emit_cond_br( $builder->emit( 'cmp_gt', 'Int', [ $builder->emit( 'add', 'ptr', [ $hp, $sz ] ), $hl ] ), $l_gc, $l_alloc );
        $builder->emit_label($l_gc);
        my $l_panic = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $allow_gc, 1 ] ), $builder->new_label(), $l_panic );
        $builder->emit_label( $builder->last_instruction->{true_l} );
        $builder->emit( 'call_func', 'void', ['M_gc_collect'] );
        $hp = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('heap_ptr') ] );
        $hl = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('heap_limit') ] );
        $builder->emit_cond_br( $builder->emit( 'cmp_gt', 'Int', [ $builder->emit( 'add', 'ptr', [ $hp, $sz ] ), $hl ] ), $l_panic, $l_alloc );
        $builder->emit_label($l_alloc);
        my $n_next = $builder->emit( 'add', 'ptr', [ $hp, $sz ] );
        $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('heap_ptr'), $n_next ] );
        $builder->emit( 'store_mem_disp', 'void', [ $hp, 0, $fhdr ] );
        my $obj_ptr = $builder->emit( 'add', 'ptr', [ $hp, 8 ] );
        my $zp_s    = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $zp_s, $obj_ptr ] );
        my $l_zl = $builder->new_label();
        my $l_ze = $builder->new_label();
        $builder->emit_label($l_zl);
        my $zp = $builder->emit( 'local_load', 'ptr', [$zp_s] );
        $builder->emit_cond_br( $builder->emit( 'cmp_lt', 'Int', [ $zp, $n_next ] ), $builder->new_label(), $l_ze );
        $builder->emit_label( $builder->last_instruction->{true_l} );
        $builder->emit( 'store_mem_disp', 'void', [ $zp, 0, 0 ] );
        $builder->emit( 'local_store', 'void', [ $zp_s, $builder->emit( 'add', 'ptr', [ $zp, 8 ] ) ] );
        $builder->emit_jump($l_zl);
        $builder->emit_label($l_ze);
        $builder->emit( 'leave_func', 'ptr', [$obj_ptr] );
        $builder->emit_label($l_panic);
        my $msg = $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string("Fatal: Out of Memory\n") ] );
        $builder->emit( 'intrinsic_print_stderr', 'void', [$msg] );
        $builder->emit( 'intrinsic_exit',         'void', [ $builder->emit( 'constant', 'i64', [1] ) ] );
        $builder->emit( 'leave_func',             'ptr',  [0] );
    }

    method inject_runtime_promote_object() {
        $driver->reset_locals();
        $builder->emit_label('M_promote_object');
        $builder->emit( 'enter_func', 'void', [] );
        my $p             = $builder->emit( 'get_arg', 'ptr', [0] );
        my $l_not_nursery = $builder->new_label();
        my $l_null_or_smi = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $p, 0 ] ), $l_null_or_smi, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        $builder->emit_cond_br( $builder->emit( 'and', 'i64', [ $p, 1 ] ), $l_null_or_smi, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        my $n_base     = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('nursery_base') ] );
        my $n_limit    = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('nursery_limit') ] );
        my $in_nursery = $builder->emit( 'and', 'i64',
            [ $builder->emit( 'cmp_ge', 'Int', [ $p, $n_base ] ), $builder->emit( 'cmp_lt', 'Int', [ $p, $n_limit ] ) ] );
        $builder->emit_cond_br( $in_nursery, $builder->new_label(), $l_not_nursery );
        $builder->emit_label( $builder->last_instruction->{true_l} );
        my $hdr            = $builder->emit( 'load_mem_disp', 'i64', [ $p, -8 ] );
        my $l_do_promote   = $builder->new_label();
        my $l_is_forwarded = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'and', 'i64', [ $builder->emit( 'shr', 'i64', [ $hdr, 61 ] ), 1 ] ), $l_is_forwarded, $l_do_promote );
        $builder->emit_label($l_is_forwarded);
        $builder->emit( 'leave_func', 'ptr',
            [ $builder->emit( 'and', 'i64', [ $hdr, $builder->emit( 'constant', 'i64', [ hex("FFFFFFFFFFFF") ] ) ] ) ] );
        $builder->emit_label($l_do_promote);
        my $sz         = $builder->emit( 'and', 'i64', [ $hdr, $builder->emit( 'constant', 'i64', [ hex("FFFFFFFFFF") ] ) ] );
        my $payload_sz = $builder->emit( 'sub', 'i64', [ $sz,  8 ] );

        # Carry RC values (and Leaf tags) from Nursery to Tenured space perfectly
        my $psz_with_flags = $builder->emit( 'or', 'i64',
            [ $payload_sz, $builder->emit( 'and', 'i64', [ $hdr, $builder->emit( 'constant', 'i64', [ hex("FFFF000000000000") ] ) ] ) ] );
        my $new_p = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc_tenured', $psz_with_flags, $builder->emit( 'constant', 'i64', [0] ) ] );
        my $ci_s  = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $ci_s, 0 ] );
        my $l_cs = $builder->new_label();
        my $l_cd = $builder->new_label();
        $builder->emit_label($l_cs);
        my $ci = $builder->emit( 'local_load', 'i64', [$ci_s] );
        $builder->emit_cond_br( $builder->emit( 'cmp_ge', 'Int', [ $ci, $payload_sz ] ), $l_cd, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );

        # Copy payload directly
        my $src_ptr = $builder->emit( 'add', 'ptr', [ $p,     $ci ] );
        my $dst_ptr = $builder->emit( 'add', 'ptr', [ $new_p, $ci ] );
        $builder->emit( 'store_mem_disp', 'void', [ $dst_ptr, 0, $builder->emit( 'load_mem_disp', 'i64', [ $src_ptr, 0 ] ) ] );
        $builder->emit( 'local_store', 'void', [ $ci_s, $builder->emit( 'add', 'i64', [ $ci, 8 ] ) ] );
        $builder->emit_jump($l_cs);
        $builder->emit_label($l_cd);
        $builder->emit( 'store_mem_disp', 'void',
            [ $p, -8, $builder->emit( 'or', 'i64', [ $builder->emit( 'constant', 'i64', [ 1 << 61 ] ), $new_p ] ) ] );
        $builder->emit( 'leave_func', 'ptr', [$new_p] );
        $builder->emit_label($l_not_nursery);
        $builder->emit_label($l_null_or_smi);
        $builder->emit( 'leave_func', 'ptr', [$p] );
    }

    method inject_runtime_evacuate_major() {
        $driver->reset_locals();
        $builder->emit_label('M_evacuate_major');
        $builder->emit( 'enter_func', 'void', [] );
        my $p             = $builder->emit( 'get_arg', 'ptr', [0] );
        my $l_not_managed = $builder->new_label();
        my $l_null_or_smi = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $p, 0 ] ), $l_null_or_smi, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        $builder->emit_cond_br( $builder->emit( 'and', 'i64', [ $p, 1 ] ), $l_null_or_smi, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        my $in_nursery = $builder->emit(
            'and', 'i64',
            [   $builder->emit( 'cmp_ge', 'Int', [ $p, $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('nursery_base') ] ) ] ),
                $builder->emit( 'cmp_lt', 'Int', [ $p, $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('nursery_limit') ] ) ] )
            ]
        );
        my $in_from = $builder->emit(
            'and', 'i64',
            [   $builder->emit( 'cmp_ge', 'Int', [ $p, $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('heap_base') ] ) ] ),
                $builder->emit( 'cmp_lt', 'Int', [ $p, $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('heap_limit') ] ) ] )
            ]
        );
        $builder->emit_cond_br( $builder->emit( 'or', 'i64', [ $in_nursery, $in_from ] ), $builder->new_label(), $l_not_managed );
        $builder->emit_label( $builder->last_instruction->{true_l} );
        my $hdr            = $builder->emit( 'load_mem_disp', 'i64', [ $p, -8 ] );
        my $l_do_evacuate  = $builder->new_label();
        my $l_is_forwarded = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'and', 'i64', [ $builder->emit( 'shr', 'i64', [ $hdr, 61 ] ), 1 ] ), $l_is_forwarded,
            $l_do_evacuate );
        $builder->emit_label($l_is_forwarded);
        $builder->emit( 'leave_func', 'ptr',
            [ $builder->emit( 'and', 'i64', [ $hdr, $builder->emit( 'constant', 'i64', [ hex("FFFFFFFFFFFF") ] ) ] ) ] );
        $builder->emit_label($l_do_evacuate);
        my $sz            = $builder->emit( 'and',           'i64', [ $hdr, $builder->emit( 'constant', 'i64', [ hex("FFFFFFFFFF") ] ) ] );
        my $new_hdr_p     = $builder->emit( 'load_iso_disp', 'ptr', [104] );
        my $new_payload_p = $builder->emit( 'add',           'ptr', [ $new_hdr_p, 8 ] );
        my $ci_s          = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $ci_s, 0 ] );
        my $l_cs = $builder->new_label();
        my $l_cd = $builder->new_label();
        $builder->emit_label($l_cs);
        my $ci = $builder->emit( 'local_load', 'i64', [$ci_s] );
        $builder->emit_cond_br( $builder->emit( 'cmp_ge', 'Int', [ $ci, $sz ] ), $l_cd, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        my $src_ptr = $builder->emit( 'add', 'ptr', [ $builder->emit( 'sub', 'ptr', [ $p, 8 ] ), $ci ] );
        my $dst_ptr = $builder->emit( 'add', 'ptr', [ $new_hdr_p, $ci ] );
        $builder->emit( 'store_mem_disp', 'void', [ $dst_ptr, 0, $builder->emit( 'load_mem_disp', 'i64', [ $src_ptr, 0 ] ) ] );
        $builder->emit( 'local_store', 'void', [ $ci_s, $builder->emit( 'add', 'i64', [ $ci, 8 ] ) ] );
        $builder->emit_jump($l_cs);
        $builder->emit_label($l_cd);
        $builder->emit( 'store_iso_disp', 'void', [ 104, $builder->emit( 'add', 'ptr', [ $new_hdr_p, $sz ] ) ] );
        $builder->emit( 'store_mem_disp', 'void',
            [ $p, -8, $builder->emit( 'or', 'i64', [ $builder->emit( 'constant', 'i64', [ 1 << 61 ] ), $new_payload_p ] ) ] );
        $builder->emit( 'leave_func', 'ptr', [$new_payload_p] );
        $builder->emit_label($l_not_managed);
        $builder->emit_label($l_null_or_smi);
        $builder->emit( 'leave_func', 'ptr', [$p] );
    }

    # --- Minor Generation Collector ---
    method inject_runtime_minor_collect() {
        $driver->reset_locals();
        $builder->emit_label('M_minor_collect');
        $builder->emit( 'enter_func', 'void', [] );
        my $orig_heap_ptr = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('heap_ptr') ] );
        $self->_emit_root_scan('M_promote_object');

        # Old-to-Young sweep
        my $sweep_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void',
            [ $sweep_s, $builder->emit( 'add', 'ptr', [ $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('heap_base') ] ), 1032 ] ) ] );

        # Pass 1: Static limit (original end of heap)
        my $limit_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $limit_s, $builder->emit( 'add', 'ptr', [ $orig_heap_ptr, 8 ] ) ] );
        $self->_emit_cheney_scan( $sweep_s, sub { $builder->emit( 'local_load', 'ptr', [$limit_s] ) }, 'M_promote_object' );

        # Pass 2: Dynamic limit for newly promoted objects
        my $scan_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $scan_s, $builder->emit( 'add', 'ptr', [ $orig_heap_ptr, 8 ] ) ] );
        $self->_emit_cheney_scan( $scan_s,
            sub { $builder->emit( 'add', 'ptr', [ $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('heap_ptr') ] ), 8 ] ) },
            'M_promote_object' );
        $builder->emit( 'store_iso_disp', 'void',
            [ $driver->iso_offset('nursery_ptr'), $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('nursery_base') ] ) ] );
        $builder->emit( 'leave_func', 'void', [] );
    }

    method inject_runtime_print_int() {
        $driver->reset_locals();
        $builder->emit_label('M_print_int');
        $builder->emit( 'enter_func', 'void', [] );
        my $n    = $builder->emit( 'div', 'i64', [ $builder->emit( 'sub', 'i64', [ $builder->emit( 'get_arg', 'i64', [0] ), 1 ] ), 2 ] );
        my $l_z  = $builder->new_label();
        my $l_nz = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $n, 0 ] ), $l_z, $l_nz );
        $builder->emit_label($l_z);
        $builder->emit( 'intrinsic_print_char', 'void', [48] );
        $builder->emit( 'leave_func',           'void', [0] );
        $builder->emit_label($l_nz);
        my $scratch_start_slot = $driver->alloc_local_slot();
        for ( 1 .. 3 ) { $driver->alloc_local_slot(); }
        my $bp       = $builder->emit( 'get_bp', 'ptr', [] );
        my $temp_buf = $builder->emit( 'sub',    'ptr', [ $bp, $scratch_start_slot ] );
        my $is       = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $is, 0 ] );
        my $ns = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $ns, $n ] );
        my $l1 = $builder->new_label();
        my $l2 = $builder->new_label();
        $builder->emit_label($l1);
        my $cn = $builder->emit( 'local_load', 'i64', [$ns] );
        my $ci = $builder->emit( 'local_load', 'i64', [$is] );
        $builder->emit( 'store_mem_byte', 'void',
            [ $temp_buf, $ci, $builder->emit( 'add', 'i64', [ $builder->emit( 'mod', 'i64', [ $cn, 10 ] ), 48 ] ) ] );
        $builder->emit( 'local_store', 'void', [ $is, $builder->emit( 'add', 'i64', [ $ci, 1 ] ) ] );
        my $nn = $builder->emit( 'div', 'i64', [ $cn, 10 ] );
        $builder->emit( 'local_store', 'void', [ $ns, $nn ] );
        $builder->emit_cond_br( $builder->emit( 'cmp_gt', 'Int', [ $nn, 0 ] ), $l1, $l2 );
        $builder->emit_label($l2);
        my $l3 = $builder->new_label();
        my $l4 = $builder->new_label();
        $builder->emit_label($l3);
        my $fci = $builder->emit( 'sub', 'i64', [ $builder->emit( 'local_load', 'i64', [$is] ), 1 ] );
        $builder->emit( 'local_store', 'void', [ $is, $fci ] );
        $builder->emit( 'intrinsic_print_char', 'void', [ $builder->emit( 'load_mem_byte', 'Int', [ $temp_buf, $fci ] ) ] );
        $builder->emit_cond_br( $builder->emit( 'cmp_gt', 'Int', [ $fci, 0 ] ), $l3, $l4 );
        $builder->emit_label($l4);
        $builder->emit( 'leave_func', 'void', [0] );
    }

    method inject_runtime_float_to_str() {
        $driver->reset_locals();
        $builder->emit_label('M_float_to_str');
        $builder->emit( 'enter_func', 'void', [] );
        my $val_reg = $builder->emit( 'get_arg', 'double', [0] );
        my $val_s   = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $val_s, $val_reg ] );

        # Allocate String Object: header + 16 bytes metadata + 32 bytes buffer = 56 bytes.
        # Align to 64 bytes for GC safety: 64 | Leaf flags (0xC000000000000000)
        my $str_obj = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', $builder->emit( 'constant', 'i64', [ 64 | hex("C000000000000000") ] ) ] );
        $builder->emit( 'shadow_push', 'void', [$str_obj] );
        my $buf_ptr = $builder->emit( 'add', 'ptr', [ $str_obj, 16 ] );
        my $pos_s   = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $pos_s, 0 ] );
        my $val = $builder->emit( 'local_load', 'double', [$val_s] );

        # Check if negative
        my $l_not_neg = $builder->new_label();
        my $is_neg    = $builder->emit( 'cmp_lt', 'double', [ $val, $builder->emit( 'constant', 'i64', [0] ) ] );
        $builder->emit_cond_br( $is_neg, $builder->new_label(), $l_not_neg );
        $builder->emit_label( $builder->last_instruction->{true_l} );
        {
            # Write '-'
            my $pos = $builder->emit( 'local_load', 'i64', [$pos_s] );
            $builder->emit( 'store_mem_byte', 'void', [ $buf_ptr, $pos, ord('-') ] );
            $builder->emit( 'local_store', 'void', [ $pos_s, $builder->emit( 'add', 'i64', [ $pos, 1 ] ) ] );

            # Negate val
            my $neg_val = $builder->emit( 'sub', 'double', [ $builder->emit( 'constant', 'i64', [0] ), $val ] );
            $builder->emit( 'local_store', 'void', [ $val_s, $neg_val ] );
        }
        $builder->emit_label($l_not_neg);

        # val is now positive.
        $val = $builder->emit( 'local_load', 'double', [$val_s] );
        my $int_part   = $builder->emit( 'cvt_f64_i64', 'i64', [$val] );
        my $int_part_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $int_part_s, $int_part ] );

        # frac = val - (double)int_part
        my $int_part_dbl = $builder->emit( 'cvt_i64_f64', 'double', [$int_part] );
        my $frac         = $builder->emit( 'sub',         'double', [ $val, $int_part_dbl ] );

        # frac_part = (int)(frac * 100000.0)
        my $frac_scaled
            = $builder->emit( 'mul', 'double', [ $frac, $builder->emit( 'constant', 'i64', [ unpack( 'Q<', pack( 'd<', 100000.0 ) ) ] ) ] );
        my $frac_part   = $builder->emit( 'cvt_f64_i64', 'i64', [$frac_scaled] );
        my $frac_part_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $frac_part_s, $frac_part ] );

        # --- Format Integer Part ---
        my $scratch_s = $driver->alloc_local_slot();
        for ( 1 .. 3 ) { $driver->alloc_local_slot() }
        my $bp       = $builder->emit( 'get_bp', 'ptr', [] );
        my $temp_buf = $builder->emit( 'sub',    'ptr', [ $bp, $scratch_s ] );
        my $is_s     = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $is_s, 0 ] );
        my $ns = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $ns, $int_part ] );
        my $l_z  = $builder->new_label();
        my $l_nz = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $int_part, 0 ] ), $l_z, $l_nz );
        $builder->emit_label($l_z);
        {
            my $pos = $builder->emit( 'local_load', 'i64', [$pos_s] );
            $builder->emit( 'store_mem_byte', 'void', [ $buf_ptr, $pos, 48 ] );
            $builder->emit( 'local_store', 'void', [ $pos_s, $builder->emit( 'add', 'i64', [ $pos, 1 ] ) ] );
        }
        $builder->emit_jump($l_nz);
        $builder->emit_label($l_nz);
        {
            # Loop to extract digits
            my $l_loop1     = $builder->new_label();
            my $l_loop1_end = $builder->new_label();
            $builder->emit_label($l_loop1);
            my $cn = $builder->emit( 'local_load', 'i64', [$ns] );
            my $ci = $builder->emit( 'local_load', 'i64', [$is_s] );
            $builder->emit( 'store_mem_byte', 'void',
                [ $temp_buf, $ci, $builder->emit( 'add', 'i64', [ $builder->emit( 'mod', 'i64', [ $cn, 10 ] ), 48 ] ) ] );
            $builder->emit( 'local_store', 'void', [ $is_s, $builder->emit( 'add', 'i64', [ $ci, 1 ] ) ] );
            my $nn = $builder->emit( 'div', 'i64', [ $cn, 10 ] );
            $builder->emit( 'local_store', 'void', [ $ns, $nn ] );
            $builder->emit_cond_br( $builder->emit( 'cmp_gt', 'Int', [ $nn, 0 ] ), $l_loop1, $l_loop1_end );
            $builder->emit_label($l_loop1_end);

            # Write in reverse order
            my $l_loop2     = $builder->new_label();
            my $l_loop2_end = $builder->new_label();
            $builder->emit_label($l_loop2);
            my $fci = $builder->emit( 'sub', 'i64', [ $builder->emit( 'local_load', 'i64', [$is_s] ), 1 ] );
            $builder->emit( 'local_store', 'void', [ $is_s, $fci ] );
            my $pos   = $builder->emit( 'local_load',    'i64', [$pos_s] );
            my $digit = $builder->emit( 'load_mem_byte', 'Int', [ $temp_buf, $fci ] );
            $builder->emit( 'store_mem_byte', 'void', [ $buf_ptr, $pos, $digit ] );
            $builder->emit( 'local_store', 'void', [ $pos_s, $builder->emit( 'add', 'i64', [ $pos, 1 ] ) ] );
            $builder->emit_cond_br( $builder->emit( 'cmp_gt', 'Int', [ $fci, 0 ] ), $l_loop2, $l_loop2_end );
            $builder->emit_label($l_loop2_end);
        }

        # --- Write '.' ---
        my $pos = $builder->emit( 'local_load', 'i64', [$pos_s] );
        $builder->emit( 'store_mem_byte', 'void', [ $buf_ptr, $pos, ord('.') ] );
        $builder->emit( 'local_store', 'void', [ $pos_s, $builder->emit( 'add', 'i64', [ $pos, 1 ] ) ] );

        # --- Format Fractional Part (5 decimal places with leading zeros) ---
        my $f_val = $builder->emit( 'local_load', 'i64', [$frac_part_s] );

        # Print leading zeros if frac_part < 10000, 1000, 100, 10
        my $divs = [ 10000, 1000, 100, 10 ];
        for my $d (@$divs) {
            my $l_no_zero = $builder->new_label();
            $builder->emit_cond_br( $builder->emit( 'cmp_lt', 'Int', [ $f_val, $d ] ), $builder->new_label(), $l_no_zero );
            $builder->emit_label( $builder->last_instruction->{true_l} );
            {
                my $pos = $builder->emit( 'local_load', 'i64', [$pos_s] );
                $builder->emit( 'store_mem_byte', 'void', [ $buf_ptr, $pos, 48 ] );
                $builder->emit( 'local_store', 'void', [ $pos_s, $builder->emit( 'add', 'i64', [ $pos, 1 ] ) ] );
            }
            $builder->emit_label($l_no_zero);
        }

        # Now print the actual frac_part digits
        $builder->emit( 'local_store', 'void', [ $ns,   $f_val ] );
        $builder->emit( 'local_store', 'void', [ $is_s, 0 ] );
        my $l_floop1     = $builder->new_label();
        my $l_floop1_end = $builder->new_label();
        $builder->emit_label($l_floop1);
        my $cn = $builder->emit( 'local_load', 'i64', [$ns] );
        my $ci = $builder->emit( 'local_load', 'i64', [$is_s] );
        $builder->emit( 'store_mem_byte', 'void',
            [ $temp_buf, $ci, $builder->emit( 'add', 'i64', [ $builder->emit( 'mod', 'i64', [ $cn, 10 ] ), 48 ] ) ] );
        $builder->emit( 'local_store', 'void', [ $is_s, $builder->emit( 'add', 'i64', [ $ci, 1 ] ) ] );
        my $nn = $builder->emit( 'div', 'i64', [ $cn, 10 ] );
        $builder->emit( 'local_store', 'void', [ $ns, $nn ] );
        $builder->emit_cond_br( $builder->emit( 'cmp_gt', 'Int', [ $nn, 0 ] ), $l_floop1, $l_floop1_end );
        $builder->emit_label($l_floop1_end);
        my $l_floop2     = $builder->new_label();
        my $l_floop2_end = $builder->new_label();
        $builder->emit_label($l_floop2);
        my $fci = $builder->emit( 'sub', 'i64', [ $builder->emit( 'local_load', 'i64', [$is_s] ), 1 ] );
        $builder->emit( 'local_store', 'void', [ $is_s, $fci ] );
        my $pos_f = $builder->emit( 'local_load',    'i64', [$pos_s] );
        my $digit = $builder->emit( 'load_mem_byte', 'Int', [ $temp_buf, $fci ] );
        $builder->emit( 'store_mem_byte', 'void', [ $buf_ptr, $pos_f, $digit ] );
        $builder->emit( 'local_store', 'void', [ $pos_s, $builder->emit( 'add', 'i64', [ $pos_f, 1 ] ) ] );
        $builder->emit_cond_br( $builder->emit( 'cmp_gt', 'Int', [ $fci, 0 ] ), $l_floop2, $l_floop2_end );
        $builder->emit_label($l_floop2_end);

        # Store final string length
        my $final_len = $builder->emit( 'local_load', 'i64', [$pos_s] );
        $builder->emit( 'store_mem_disp', 'void', [ $str_obj, 0, $final_len ] );
        $builder->emit( 'store_mem_disp', 'void', [ $str_obj, 8, $final_len ] );
        $builder->emit( 'shadow_pop',     'void', [] );
        $builder->emit( 'leave_func',     'ptr',  [$str_obj] );
    }

    method inject_runtime_print_any() {
        $driver->reset_locals();
        $builder->emit_label('M_print_any');
        $builder->emit( 'enter_func', 'void', [] );
        my $v           = $builder->emit( 'get_arg', 'i64', [0] );
        my $l_undef     = $builder->new_label();
        my $l_not_undef = $builder->new_label();
        my $uptr        = $builder->emit( 'load_data_addr', 'ptr', [$undef_ptr_offset] );
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $v, $uptr ] ), $l_undef, $l_not_undef );
        $builder->emit_label($l_undef);
        $builder->emit( 'intrinsic_print', 'void', [ $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string("undef") ] ) ] );
        $builder->emit( 'leave_func',      'void', [0] );
        $builder->emit_label($l_not_undef);
        my $l_t = $builder->new_label();
        my $l_f = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'and', 'i64', [ $v, 1 ] ), $l_t, $l_f );
        $builder->emit_label($l_t);
        $builder->emit( 'call_func',  'void', [ 'M_print_int', $v ] );
        $builder->emit( 'leave_func', 'void', [0] );
        $builder->emit_label($l_f);
        my $str = $builder->emit( 'call_func', 'ptr', [ 'M_any_to_str', $v ] );
        $builder->emit( 'intrinsic_print', 'void', [$str] );
        $builder->emit( 'leave_func',      'void', [0] );
    }

    method inject_runtime_dump() {
        $driver->reset_locals();
        $builder->emit_label('M_dump');
        $builder->emit( 'enter_func', 'void', [] );
        my $v = $builder->emit( 'get_arg', 'i64', [0] );
        $builder->emit( 'call_func',       'void', [ 'M_dump_recursive', $v, $builder->emit( 'constant', 'i64', [1] ) ] );
        $builder->emit( 'intrinsic_print', 'void', [ $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string("\n") ] ) ] );
        $builder->emit( 'leave_func',      'void', [0] );
        $self->inject_runtime_dump_recursive();
    }

    method inject_runtime_dump_recursive() {
        $driver->reset_locals();
        $builder->emit_label('M_dump_recursive');
        $builder->emit( 'enter_func', 'void', [] );
        my $val_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $val_s, $builder->emit( 'get_arg', 'i64', [0] ) ] );
        my $indent_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $indent_s, $builder->emit( 'get_arg', 'i64', [1] ) ] );
        my $val = $builder->emit( 'local_load', 'i64', [$val_s] );

        # 1. SMI (Int)
        my $l_not_smi = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'and', 'i64', [ $val, 1 ] ), $builder->new_label(), $l_not_smi );
        $builder->emit_label( $builder->last_instruction->{true_l} );
        $builder->emit( 'call_func',  'void', [ 'M_print_int', $val ] );
        $builder->emit( 'leave_func', 'void', [0] );
        $builder->emit_label($l_not_smi);

        # 2. Undef
        my $uptr        = $builder->emit( 'load_data_addr', 'ptr', [$undef_ptr_offset] );
        my $l_not_undef = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $val, $uptr ] ), $builder->new_label(), $l_not_undef );
        $builder->emit_label( $builder->last_instruction->{true_l} );
        $builder->emit( 'intrinsic_print', 'void', [ $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string("null") ] ) ] );
        $builder->emit( 'leave_func',      'void', [0] );
        $builder->emit_label($l_not_undef);

        # 3. String
        my $hdr       = $builder->emit( 'load_mem_disp', 'i64', [ $val, -8 ] );
        my $is_str    = $builder->emit( 'cmp_eq', 'Int', [ $builder->emit( 'shr', 'i64', [ $hdr, 62 ] ), 3 ] );
        my $l_not_str = $builder->new_label();
        $builder->emit_cond_br( $is_str, $builder->new_label(), $l_not_str );
        $builder->emit_label( $builder->last_instruction->{true_l} );
        $builder->emit( 'intrinsic_print_char', 'void', [ ord('"') ] );
        $builder->emit( 'intrinsic_print',      'void', [$val] );
        $builder->emit( 'intrinsic_print_char', 'void', [ ord('"') ] );
        $builder->emit( 'leave_func',           'void', [0] );
        $builder->emit_label($l_not_str);

        # 4. Complex types
        my $first      = $builder->emit( 'load_mem_disp', 'i64', [ $val,   0 ] );
        my $tag        = $builder->emit( 'and',           'i64', [ $first, 3 ] );
        my $l_is_array = $builder->new_label();
        my $l_is_tuple = $builder->new_label();
        my $l_is_hash  = $builder->new_label();
        my $l_is_obj   = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $tag, 1 ] ), $l_is_array, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $tag, 2 ] ), $l_is_tuple, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $tag, 3 ] ), $l_is_hash, $l_is_obj );
        $builder->emit_label($l_is_array);
        $self->_emit_runtime_dump_list( $val_s, $indent_s, ord('['), ord(']') );
        $builder->emit( 'leave_func', 'void', [0] );
        $builder->emit_label($l_is_tuple);
        $self->_emit_runtime_dump_list( $val_s, $indent_s, ord('('), ord(')') );
        $builder->emit( 'leave_func', 'void', [0] );
        $builder->emit_label($l_is_hash);
        $self->_emit_runtime_dump_hash( $val_s, $indent_s );
        $builder->emit( 'leave_func', 'void', [0] );
        $builder->emit_label($l_is_obj);
        $builder->emit( 'intrinsic_print', 'void',
            [ $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string('{"type":"Object"}') ] ) ] );
        $builder->emit( 'leave_func', 'void', [0] );
    }

    method inject_runtime_ddx() {
        $driver->reset_locals();
        $builder->emit_label('M_ddx');
        $builder->emit( 'enter_func', 'void', [] );
        my $v = $builder->emit( 'get_arg', 'i64', [0] );
        $builder->emit( 'call_func',              'void', [ 'M_ddx_val', $v, $builder->emit( 'constant', 'i64', [1] ) ] );
        $builder->emit( 'intrinsic_print_stderr', 'void', [ $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string("\n") ] ) ] );
        $builder->emit( 'leave_func',             'void', [0] );
        $self->inject_runtime_ddx_val();
    }

    method inject_runtime_ddx_val() {
        $driver->reset_locals();
        $builder->emit_label('M_ddx_val');
        $builder->emit( 'enter_func', 'void', [] );
        my $val_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $val_s, $builder->emit( 'get_arg', 'i64', [0] ) ] );
        my $indent_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $indent_s, $builder->emit( 'get_arg', 'i64', [1] ) ] );
        my $val = $builder->emit( 'local_load', 'i64', [$val_s] );

        # 1. SMI (Int)
        my $l_not_smi = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'and', 'i64', [ $val, 1 ] ), $builder->new_label(), $l_not_smi );
        $builder->emit_label( $builder->last_instruction->{true_l} );
        $builder->emit( 'call_func',  'void', [ 'M_print_int', $val ] );
        $builder->emit( 'leave_func', 'void', [0] );
        $builder->emit_label($l_not_smi);

        # 2. Undef
        my $uptr        = $builder->emit( 'load_data_addr', 'ptr', [$undef_ptr_offset] );
        my $l_not_undef = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $val, $uptr ] ), $builder->new_label(), $l_not_undef );
        $builder->emit_label( $builder->last_instruction->{true_l} );
        $builder->emit( 'intrinsic_print_stderr', 'void', [ $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string("undef") ] ) ] );
        $builder->emit( 'leave_func',             'void', [0] );
        $builder->emit_label($l_not_undef);

        # 3. String
        my $hdr       = $builder->emit( 'load_mem_disp', 'i64', [ $val, -8 ] );
        my $is_str    = $builder->emit( 'cmp_eq', 'Int', [ $builder->emit( 'shr', 'i64', [ $hdr, 62 ] ), 3 ] );
        my $l_not_str = $builder->new_label();
        $builder->emit_cond_br( $is_str, $builder->new_label(), $l_not_str );
        $builder->emit_label( $builder->last_instruction->{true_l} );
        $builder->emit( 'intrinsic_print_stderr_char', 'void', [ ord('"') ] );
        $builder->emit( 'intrinsic_print_stderr',      'void', [$val] );
        $builder->emit( 'intrinsic_print_stderr_char', 'void', [ ord('"') ] );
        $builder->emit( 'leave_func',                  'void', [0] );
        $builder->emit_label($l_not_str);

        # 4. Complex types
        my $first      = $builder->emit( 'load_mem_disp', 'i64', [ $val,   0 ] );
        my $tag        = $builder->emit( 'and',           'i64', [ $first, 3 ] );
        my $l_is_array = $builder->new_label();
        my $l_is_tuple = $builder->new_label();
        my $l_is_hash  = $builder->new_label();
        my $l_is_obj   = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $tag, 1 ] ), $l_is_array, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $tag, 2 ] ), $l_is_tuple, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $tag, 3 ] ), $l_is_hash, $l_is_obj );
        $builder->emit_label($l_is_array);
        $self->_emit_runtime_ddx_list( $val_s, $indent_s, ord('['), ord(']') );
        $builder->emit( 'leave_func', 'void', [0] );
        $builder->emit_label($l_is_tuple);
        $self->_emit_runtime_ddx_list( $val_s, $indent_s, ord('('), ord(')') );
        $builder->emit( 'leave_func', 'void', [0] );
        $builder->emit_label($l_is_hash);
        $self->_emit_runtime_ddx_hash( $val_s, $indent_s );
        $builder->emit( 'leave_func', 'void', [0] );
        $builder->emit_label($l_is_obj);
        $builder->emit( 'intrinsic_print_stderr', 'void',
            [ $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string('{"type":"Object"}') ] ) ] );
        $builder->emit( 'leave_func', 'void', [0] );
    }

    method _emit_runtime_ddx_list( $val_s, $indent_s, $open, $close ) {
        my $val = $builder->emit( 'local_load', 'ptr', [$val_s] );
        $builder->emit( 'shadow_push',                 'void', [$val] );
        $builder->emit( 'intrinsic_print_stderr_char', 'void', [$open] );
        my $qword = $builder->emit( 'load_mem_disp', 'i64', [ $val,   0 ] );
        my $count = $builder->emit( 'shr',           'i64', [ $qword, 2 ] );
        my $i_s   = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $i_s, 0 ] );
        my $l_loop = $builder->new_label();
        my $l_done = $builder->new_label();
        $builder->emit_label($l_loop);
        my $i = $builder->emit( 'local_load', 'i64', [$i_s] );
        $builder->emit_cond_br( $builder->emit( 'cmp_ge', 'Int', [ $i, $count ] ), $l_done, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        my $l_no_comma = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $i, 0 ] ), $l_no_comma, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        $builder->emit( 'intrinsic_print_stderr', 'void', [ $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string(", ") ] ) ] );
        $builder->emit_label($l_no_comma);
        my $curr_val = $builder->emit( 'local_load', 'ptr', [$val_s] );
        my $elem_ptr
            = $builder->emit( 'add', 'ptr', [ $curr_val, $builder->emit( 'add', 'i64', [ 8, $builder->emit( 'mul', 'i64', [ $i, 8 ] ) ] ) ] );
        my $elem        = $builder->emit( 'load_mem_disp', 'i64', [ $elem_ptr, 0 ] );
        my $next_indent = $builder->emit( 'add', 'i64', [ $builder->emit( 'local_load', 'i64', [$indent_s] ), 2 ] );
        $builder->emit( 'call_func', 'void', [ 'M_ddx_val', $elem, $next_indent ] );
        $builder->emit( 'local_store', 'void', [ $i_s, $builder->emit( 'add', 'i64', [ $i, 1 ] ) ] );
        $builder->emit_jump($l_loop);
        $builder->emit_label($l_done);
        $builder->emit( 'intrinsic_print_stderr_char', 'void', [$close] );
        $builder->emit( 'shadow_pop',                  'void', [] );
    }

    method _emit_runtime_ddx_hash( $val_s, $indent_s ) {
        my $val = $builder->emit( 'local_load', 'ptr', [$val_s] );
        $builder->emit( 'shadow_push',                 'void', [$val] );
        $builder->emit( 'intrinsic_print_stderr_char', 'void', [ ord('{') ] );
        my $keys_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $keys_s, $builder->emit( 'call_func', 'ptr', [ 'M_hash_keys', $val ] ) ] );
        my $keys = $builder->emit( 'local_load', 'ptr', [$keys_s] );
        $builder->emit( 'shadow_push', 'void', [$keys] );
        my $qword = $builder->emit( 'load_mem_disp', 'i64', [ $keys,  0 ] );
        my $count = $builder->emit( 'shr',           'i64', [ $qword, 2 ] );
        my $i_s   = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $i_s, 0 ] );
        my $l_loop = $builder->new_label();
        my $l_done = $builder->new_label();
        $builder->emit_label($l_loop);
        my $i = $builder->emit( 'local_load', 'i64', [$i_s] );
        $builder->emit_cond_br( $builder->emit( 'cmp_ge', 'Int', [ $i, $count ] ), $l_done, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        my $l_no_comma = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $i, 0 ] ), $l_no_comma, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        $builder->emit( 'intrinsic_print_stderr', 'void', [ $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string(", ") ] ) ] );
        $builder->emit_label($l_no_comma);
        my $curr_keys = $builder->emit( 'local_load', 'ptr', [$keys_s] );
        my $key_ptr
            = $builder->emit( 'add', 'ptr', [ $curr_keys, $builder->emit( 'add', 'i64', [ 8, $builder->emit( 'mul', 'i64', [ $i, 8 ] ) ] ) ] );
        my $key         = $builder->emit( 'load_mem_disp', 'i64', [ $key_ptr, 0 ] );
        my $next_indent = $builder->emit( 'add', 'i64', [ $builder->emit( 'local_load', 'i64', [$indent_s] ), 2 ] );
        $builder->emit( 'call_func', 'void', [ 'M_ddx_val', $key, $next_indent ] );
        $builder->emit( 'intrinsic_print_stderr', 'void', [ $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string(": ") ] ) ] );
        my $curr_hash = $builder->emit( 'local_load', 'ptr', [$val_s] );
        my $value     = $builder->emit( 'call_func',  'Any', [ 'M_hash_lookup', $curr_hash, $key ] );
        $builder->emit( 'call_func', 'void', [ 'M_ddx_val', $value, $next_indent ] );
        $builder->emit( 'local_store', 'void', [ $i_s, $builder->emit( 'add', 'i64', [ $i, 1 ] ) ] );
        $builder->emit_jump($l_loop);
        $builder->emit_label($l_done);
        $builder->emit( 'intrinsic_print_stderr_char', 'void', [ ord('}') ] );
        $builder->emit( 'shadow_pop',                  'void', [] );
        $builder->emit( 'shadow_pop',                  'void', [] );
    }

    method inject_runtime_dd() {
        $driver->reset_locals();
        $builder->emit_label('M_dd');
        $builder->emit( 'enter_func', 'void', [] );
        my $val   = $builder->emit( 'get_arg', 'i64', [0] );
        my $buf_s = $driver->alloc_local_slot();
        for ( 1 .. 255 ) { $driver->alloc_local_slot() }
        my $buf_ptr = $builder->emit( 'sub', 'ptr', [ $builder->emit( 'get_bp', 'ptr', [] ), $buf_s ] );
        my $pos_s   = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $pos_s, 0 ] );
        my $pos_ptr = $builder->emit( 'sub', 'ptr', [ $builder->emit( 'get_bp', 'ptr', [] ), $pos_s ] );
        $builder->emit( 'shadow_push', 'void', [$buf_ptr] );
        $builder->emit( 'shadow_push', 'void', [$pos_ptr] );
        $builder->emit( 'call_func',   'void', [ 'M_dd_val', $val, $builder->emit( 'constant', 'i64', [1] ), $buf_ptr, $pos_ptr ] );
        my $final_pos = $builder->emit( 'load_mem_disp', 'i64', [ $pos_ptr, 0 ] );
        my $ns_ptr    = $builder->emit(
            'call_func',
            'ptr',
            [   'M_gc_alloc',
                $builder->emit(
                    'or', 'i64',
                    [ $builder->emit( 'add', 'i64', [ $final_pos, 16 ] ), $builder->emit( 'constant', 'i64', [ hex("C000000000000000") ] ) ]
                )
            ]
        );
        $builder->emit( 'store_mem_disp', 'void', [ $ns_ptr, 0, $final_pos ] );
        my $i_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $i_s, 0 ] );
        my $l_cs = $builder->new_label();
        my $l_ce = $builder->new_label();
        $builder->emit_label($l_cs);
        my $ci        = $builder->emit( 'local_load', 'i64', [$i_s] );
        my $l_cs_body = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_lt', 'Int', [ $ci, $final_pos ] ), $l_cs_body, $l_ce );
        $builder->emit_label($l_cs_body);
        $builder->emit( 'store_mem_byte', 'void',
            [ $ns_ptr, $builder->emit( 'add', 'i64', [ $ci, 16 ] ), $builder->emit( 'load_mem_byte', 'i64', [ $buf_ptr, $ci ] ) ] );
        $builder->emit( 'local_store', 'void', [ $i_s, $builder->emit( 'add', 'i64', [ $ci, 1 ] ) ] );
        $builder->emit_jump($l_cs);
        $builder->emit_label($l_ce);
        $builder->emit( 'shadow_pop', 'void', [] );
        $builder->emit( 'shadow_pop', 'void', [] );
        $builder->emit( 'leave_func', 'void', [$ns_ptr] );
        $self->inject_runtime_dd_val();
    }

    method inject_runtime_dd_val() {
        $driver->reset_locals();
        $builder->emit_label('M_dd_val');
        $builder->emit( 'enter_func', 'void', [] );
        my $val_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $val_s, $builder->emit( 'get_arg', 'i64', [0] ) ] );
        my $indent_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $indent_s, $builder->emit( 'get_arg', 'i64', [1] ) ] );
        my $buf_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $buf_s, $builder->emit( 'get_arg', 'ptr', [2] ) ] );
        my $pp_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $pp_s, $builder->emit( 'get_arg', 'ptr', [3] ) ] );
        my $val     = $builder->emit( 'local_load', 'i64', [$val_s] );
        my $buf_ptr = $builder->emit( 'local_load', 'ptr', [$buf_s] );
        my $pos_ptr = $builder->emit( 'local_load', 'ptr', [$pp_s] );

        # helper to emit: *pos_ptr = *pos_ptr + n; (position advance)
        my $adv_pos = sub ($n) {
            $builder->emit( 'store_mem_disp', 'void',
                [ $pos_ptr, 0, $builder->emit( 'add', 'i64', [ $builder->emit( 'load_mem_disp', 'i64', [ $pos_ptr, 0 ] ), $n ] ) ] );
        };
        my $append_char = sub ($ch) {
            my $cp = $builder->emit( 'load_mem_disp', 'i64', [ $pos_ptr, 0 ] );
            $builder->emit( 'store_mem_byte', 'void', [ $buf_ptr, $cp, $ch ] );
            $adv_pos->(1);
        };
        my $append_str_literal = sub ($str) {
            my $str_ptr = $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string($str) ] );
            my $len     = length($str);
            my $li_s    = $driver->alloc_local_slot();
            $builder->emit( 'local_store', 'void', [ $li_s, 0 ] );
            my $l_ls = $builder->new_label();
            my $l_le = $builder->new_label();
            $builder->emit_label($l_ls);
            my $lci       = $builder->emit( 'local_load', 'i64', [$li_s] );
            my $l_ls_body = $builder->new_label();
            $builder->emit_cond_br( $builder->emit( 'cmp_lt', 'Int', [ $lci, $len ] ), $l_ls_body, $l_le );
            $builder->emit_label($l_ls_body);
            my $cp = $builder->emit( 'load_mem_disp', 'i64', [ $pos_ptr, 0 ] );
            $builder->emit(
                'store_mem_byte',
                'void',
                [   $buf_ptr,
                    $builder->emit( 'add',           'i64', [ $cp,      $lci ] ),
                    $builder->emit( 'load_mem_byte', 'i64', [ $str_ptr, $builder->emit( 'add', 'i64', [ $lci, 16 ] ) ] )
                ]
            );
            $builder->emit( 'local_store', 'void', [ $li_s, $builder->emit( 'add', 'i64', [ $lci, 1 ] ) ] );
            $builder->emit_jump($l_ls);
            $builder->emit_label($l_le);
            $adv_pos->($len);
        };

        # 1. SMI (Int)
        my $l_not_smi = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'and', 'i64', [ $val, 1 ] ), $builder->new_label(), $l_not_smi );
        $builder->emit_label( $builder->last_instruction->{true_l} );

        # convert int to digits in temp buffer, then write reversed
        my $scratch_s = $driver->alloc_local_slot();
        for ( 1 .. 3 ) { $driver->alloc_local_slot() }
        my $bp       = $builder->emit( 'get_bp', 'ptr', [] );
        my $temp_buf = $builder->emit( 'sub',    'ptr', [ $bp, $scratch_s ] );
        my $is       = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $is, 0 ] );
        my $n    = $builder->emit( 'div', 'i64', [ $builder->emit( 'sub', 'i64', [ $val, 1 ] ), 2 ] );
        my $l_z  = $builder->new_label();
        my $l_nz = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $n, 0 ] ), $l_z, $l_nz );
        $builder->emit_label($l_z);
        $append_char->(48);
        $builder->emit( 'leave_func', 'void', [0] );
        $builder->emit_label($l_nz);
        my $ns = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $ns, $n ] );
        my $l1 = $builder->new_label();
        my $l2 = $builder->new_label();
        $builder->emit_label($l1);
        my $cn = $builder->emit( 'local_load', 'i64', [$ns] );
        my $ci = $builder->emit( 'local_load', 'i64', [$is] );
        $builder->emit( 'store_mem_byte', 'void',
            [ $temp_buf, $ci, $builder->emit( 'add', 'i64', [ $builder->emit( 'mod', 'i64', [ $cn, 10 ] ), 48 ] ) ] );
        $builder->emit( 'local_store', 'void', [ $is, $builder->emit( 'add', 'i64', [ $ci, 1 ] ) ] );
        my $nn = $builder->emit( 'div', 'i64', [ $cn, 10 ] );
        $builder->emit( 'local_store', 'void', [ $ns, $nn ] );
        $builder->emit_cond_br( $builder->emit( 'cmp_gt', 'Int', [ $nn, 0 ] ), $l1, $l2 );
        $builder->emit_label($l2);

        # write reversed digits to buffer
        my $l3 = $builder->new_label();
        my $l4 = $builder->new_label();
        $builder->emit_label($l3);
        my $fci = $builder->emit( 'sub', 'i64', [ $builder->emit( 'local_load', 'i64', [$is] ), 1 ] );
        $builder->emit( 'local_store', 'void', [ $is, $fci ] );
        $append_char->( $builder->emit( 'load_mem_byte', 'Int', [ $temp_buf, $fci ] ) );
        $builder->emit_cond_br( $builder->emit( 'cmp_gt', 'Int', [ $fci, 0 ] ), $l3, $l4 );
        $builder->emit_label($l4);
        $builder->emit( 'leave_func', 'void', [0] );
        $builder->emit_label($l_not_smi);

        # 2. Undef
        my $uptr        = $builder->emit( 'load_data_addr', 'ptr', [$undef_ptr_offset] );
        my $l_not_undef = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $val, $uptr ] ), $builder->new_label(), $l_not_undef );
        $builder->emit_label( $builder->last_instruction->{true_l} );
        $append_str_literal->("undef");
        $builder->emit( 'leave_func', 'void', [0] );
        $builder->emit_label($l_not_undef);

        # 3. String
        my $hdr       = $builder->emit( 'load_mem_disp', 'i64', [ $val, -8 ] );
        my $is_str    = $builder->emit( 'cmp_eq', 'Int', [ $builder->emit( 'shr', 'i64', [ $hdr, 62 ] ), 3 ] );
        my $l_not_str = $builder->new_label();
        $builder->emit_cond_br( $is_str, $builder->new_label(), $l_not_str );
        $builder->emit_label( $builder->last_instruction->{true_l} );
        $append_char->( ord('"') );

        # copy string content
        my $str_len = $builder->emit( 'load_mem_disp', 'i64', [ $val, 0 ] );
        my $sl_s    = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $sl_s, 0 ] );
        my $l_sls = $builder->new_label();
        my $l_sle = $builder->new_label();
        $builder->emit_label($l_sls);
        my $sci        = $builder->emit( 'local_load', 'i64', [$sl_s] );
        my $l_sls_body = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_lt', 'Int', [ $sci, $str_len ] ), $l_sls_body, $l_sle );
        $builder->emit_label($l_sls_body);
        my $cp = $builder->emit( 'load_mem_disp', 'i64', [ $pos_ptr, 0 ] );
        $builder->emit(
            'store_mem_byte',
            'void',
            [   $buf_ptr,
                $builder->emit( 'add',           'i64', [ $cp,  $sci ] ),
                $builder->emit( 'load_mem_byte', 'i64', [ $val, $builder->emit( 'add', 'i64', [ $sci, 16 ] ) ] )
            ]
        );
        $builder->emit( 'local_store', 'void', [ $sl_s, $builder->emit( 'add', 'i64', [ $sci, 1 ] ) ] );
        $builder->emit_jump($l_sls);
        $builder->emit_label($l_sle);
        $adv_pos->( $builder->emit( 'load_mem_disp', 'i64', [ $val, 0 ] ) );
        $append_char->( ord('"') );
        $builder->emit( 'leave_func', 'void', [0] );
        $builder->emit_label($l_not_str);

        # 4. Complex types
        my $first      = $builder->emit( 'load_mem_disp', 'i64', [ $val,   0 ] );
        my $tag        = $builder->emit( 'and',           'i64', [ $first, 3 ] );
        my $l_is_array = $builder->new_label();
        my $l_is_tuple = $builder->new_label();
        my $l_is_hash  = $builder->new_label();
        my $l_is_obj   = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $tag, 1 ] ), $l_is_array, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $tag, 2 ] ), $l_is_tuple, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $tag, 3 ] ), $l_is_hash, $l_is_obj );
        $builder->emit_label($l_is_array);
        $self->_emit_runtime_dd_list( $val_s, $buf_s, $pp_s, ord('['), ord(']') );
        $builder->emit( 'leave_func', 'void', [0] );
        $builder->emit_label($l_is_tuple);
        $self->_emit_runtime_dd_list( $val_s, $buf_s, $pp_s, ord('('), ord(')') );
        $builder->emit( 'leave_func', 'void', [0] );
        $builder->emit_label($l_is_hash);
        $self->_emit_runtime_dd_hash( $val_s, $buf_s, $pp_s );
        $builder->emit( 'leave_func', 'void', [0] );
        $builder->emit_label($l_is_obj);
        $append_str_literal->('{"type":"Object"}');
        $builder->emit( 'leave_func', 'void', [0] );
    }

    method _emit_runtime_dd_list( $val_s, $buf_s, $pp_s, $open, $close ) {
        my $buf_ptr = $builder->emit( 'local_load', 'ptr', [$buf_s] );
        my $pos_ptr = $builder->emit( 'local_load', 'ptr', [$pp_s] );
        my $val     = $builder->emit( 'local_load', 'ptr', [$val_s] );
        $builder->emit( 'shadow_push', 'void', [$val] );
        my $cp = $builder->emit( 'load_mem_disp', 'i64', [ $pos_ptr, 0 ] );
        $builder->emit( 'store_mem_byte', 'void', [ $buf_ptr, $cp, $open ] );
        $builder->emit( 'store_mem_disp', 'void', [ $pos_ptr, 0, $builder->emit( 'add', 'i64', [ $cp, 1 ] ) ] );
        my $qword = $builder->emit( 'load_mem_disp', 'i64', [ $val,   0 ] );
        my $count = $builder->emit( 'shr',           'i64', [ $qword, 2 ] );
        my $i_s   = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $i_s, 0 ] );
        my $l_loop = $builder->new_label();
        my $l_done = $builder->new_label();
        $builder->emit_label($l_loop);
        my $i = $builder->emit( 'local_load', 'i64', [$i_s] );
        $builder->emit_cond_br( $builder->emit( 'cmp_ge', 'Int', [ $i, $count ] ), $l_done, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        my $l_no_comma = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $i, 0 ] ), $l_no_comma, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );

        # write ", "
        my $l_bp = $builder->emit( 'load_mem_disp', 'i64', [ $pos_ptr, 0 ] );
        $builder->emit( 'store_mem_byte', 'void', [ $buf_ptr, $l_bp, ord(',') ] );
        $builder->emit( 'store_mem_byte', 'void', [ $buf_ptr, $builder->emit( 'add', 'i64', [ $l_bp, 1 ] ), ord(' ') ] );
        $builder->emit( 'store_mem_disp', 'void', [ $pos_ptr, 0, $builder->emit( 'add', 'i64', [ $l_bp, 2 ] ) ] );
        $builder->emit_label($l_no_comma);
        my $curr_val = $builder->emit( 'local_load', 'ptr', [$val_s] );
        my $elem_ptr
            = $builder->emit( 'add', 'ptr', [ $curr_val, $builder->emit( 'add', 'i64', [ 8, $builder->emit( 'mul', 'i64', [ $i, 8 ] ) ] ) ] );
        my $elem = $builder->emit( 'load_mem_disp', 'i64', [ $elem_ptr, 0 ] );
        $builder->emit( 'call_func', 'void', [ 'M_dd_val', $elem, $builder->emit( 'constant', 'i64', [1] ), $buf_ptr, $pos_ptr ] );
        $builder->emit( 'local_store', 'void', [ $i_s, $builder->emit( 'add', 'i64', [ $i, 1 ] ) ] );
        $builder->emit_jump($l_loop);
        $builder->emit_label($l_done);
        my $lb_cp = $builder->emit( 'load_mem_disp', 'i64', [ $pos_ptr, 0 ] );
        $builder->emit( 'store_mem_byte', 'void', [ $buf_ptr, $lb_cp, $close ] );
        $builder->emit( 'store_mem_disp', 'void', [ $pos_ptr, 0, $builder->emit( 'add', 'i64', [ $lb_cp, 1 ] ) ] );
        $builder->emit( 'shadow_pop',     'void', [] );
    }

    method _emit_runtime_dd_hash( $val_s, $buf_s, $pp_s ) {
        my $buf_ptr = $builder->emit( 'local_load', 'ptr', [$buf_s] );
        my $pos_ptr = $builder->emit( 'local_load', 'ptr', [$pp_s] );
        my $val     = $builder->emit( 'local_load', 'ptr', [$val_s] );
        $builder->emit( 'shadow_push', 'void', [$val] );
        my $cp = $builder->emit( 'load_mem_disp', 'i64', [ $pos_ptr, 0 ] );
        $builder->emit( 'store_mem_byte', 'void', [ $buf_ptr, $cp, ord('{') ] );
        $builder->emit( 'store_mem_disp', 'void', [ $pos_ptr, 0, $builder->emit( 'add', 'i64', [ $cp, 1 ] ) ] );
        my $keys_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $keys_s, $builder->emit( 'call_func', 'ptr', [ 'M_hash_keys', $val ] ) ] );
        my $keys = $builder->emit( 'local_load', 'ptr', [$keys_s] );
        $builder->emit( 'shadow_push', 'void', [$keys] );
        my $qword = $builder->emit( 'load_mem_disp', 'i64', [ $keys,  0 ] );
        my $count = $builder->emit( 'shr',           'i64', [ $qword, 2 ] );
        my $i_s   = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $i_s, 0 ] );
        my $l_loop = $builder->new_label();
        my $l_done = $builder->new_label();
        $builder->emit_label($l_loop);
        my $i = $builder->emit( 'local_load', 'i64', [$i_s] );
        $builder->emit_cond_br( $builder->emit( 'cmp_ge', 'Int', [ $i, $count ] ), $l_done, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        my $l_no_comma = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $i, 0 ] ), $l_no_comma, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        my $l_bp = $builder->emit( 'load_mem_disp', 'i64', [ $pos_ptr, 0 ] );
        $builder->emit( 'store_mem_byte', 'void', [ $buf_ptr, $l_bp, ord(',') ] );
        $builder->emit( 'store_mem_byte', 'void', [ $buf_ptr, $builder->emit( 'add', 'i64', [ $l_bp, 1 ] ), ord(' ') ] );
        $builder->emit( 'store_mem_disp', 'void', [ $pos_ptr, 0, $builder->emit( 'add', 'i64', [ $l_bp, 2 ] ) ] );
        $builder->emit_label($l_no_comma);
        my $curr_keys = $builder->emit( 'local_load', 'ptr', [$keys_s] );
        my $key_ptr
            = $builder->emit( 'add', 'ptr', [ $curr_keys, $builder->emit( 'add', 'i64', [ 8, $builder->emit( 'mul', 'i64', [ $i, 8 ] ) ] ) ] );
        my $key = $builder->emit( 'load_mem_disp', 'i64', [ $key_ptr, 0 ] );
        $builder->emit( 'call_func', 'void', [ 'M_dd_val', $key, $builder->emit( 'constant', 'i64', [1] ), $buf_ptr, $pos_ptr ] );
        my $l_bp2 = $builder->emit( 'load_mem_disp', 'i64', [ $pos_ptr, 0 ] );
        $builder->emit( 'store_mem_byte', 'void', [ $buf_ptr, $l_bp2, ord(':') ] );
        $builder->emit( 'store_mem_byte', 'void', [ $buf_ptr, $builder->emit( 'add', 'i64', [ $l_bp2, 1 ] ), ord(' ') ] );
        $builder->emit( 'store_mem_disp', 'void', [ $pos_ptr, 0, $builder->emit( 'add', 'i64', [ $l_bp2, 2 ] ) ] );
        my $curr_hash = $builder->emit( 'local_load', 'ptr', [$val_s] );
        my $value     = $builder->emit( 'call_func',  'Any', [ 'M_hash_lookup', $curr_hash, $key ] );
        $builder->emit( 'call_func', 'void', [ 'M_dd_val', $value, $builder->emit( 'constant', 'i64', [1] ), $buf_ptr, $pos_ptr ] );
        $builder->emit( 'local_store', 'void', [ $i_s, $builder->emit( 'add', 'i64', [ $i, 1 ] ) ] );
        $builder->emit_jump($l_loop);
        $builder->emit_label($l_done);
        my $lb_cp = $builder->emit( 'load_mem_disp', 'i64', [ $pos_ptr, 0 ] );
        $builder->emit( 'store_mem_byte', 'void', [ $buf_ptr, $lb_cp, ord('}') ] );
        $builder->emit( 'store_mem_disp', 'void', [ $pos_ptr, 0, $builder->emit( 'add', 'i64', [ $lb_cp, 1 ] ) ] );
        $builder->emit( 'shadow_pop',     'void', [] );
        $builder->emit( 'shadow_pop',     'void', [] );
    }

    method _emit_runtime_dump_list( $val_s, $indent_s, $open, $close ) {
        my $val = $builder->emit( 'local_load', 'ptr', [$val_s] );
        $builder->emit( 'shadow_push',          'void', [$val] );
        $builder->emit( 'intrinsic_print_char', 'void', [$open] );
        my $qword = $builder->emit( 'load_mem_disp', 'i64', [ $val,   0 ] );
        my $count = $builder->emit( 'shr',           'i64', [ $qword, 2 ] );
        my $i_s   = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $i_s, 0 ] );
        my $l_loop = $builder->new_label();
        my $l_done = $builder->new_label();
        $builder->emit_label($l_loop);
        my $i = $builder->emit( 'local_load', 'i64', [$i_s] );
        $builder->emit_cond_br( $builder->emit( 'cmp_ge', 'Int', [ $i, $count ] ), $l_done, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        my $l_no_comma = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $i, 0 ] ), $l_no_comma, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        $builder->emit( 'intrinsic_print', 'void', [ $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string(", ") ] ) ] );
        $builder->emit_label($l_no_comma);
        my $curr_val = $builder->emit( 'local_load', 'ptr', [$val_s] );
        my $elem_ptr
            = $builder->emit( 'add', 'ptr', [ $curr_val, $builder->emit( 'add', 'i64', [ 8, $builder->emit( 'mul', 'i64', [ $i, 8 ] ) ] ) ] );
        my $elem        = $builder->emit( 'load_mem_disp', 'i64', [ $elem_ptr, 0 ] );
        my $next_indent = $builder->emit( 'add', 'i64', [ $builder->emit( 'local_load', 'i64', [$indent_s] ), 2 ] );
        $builder->emit( 'call_func', 'void', [ 'M_dump_recursive', $elem, $next_indent ] );
        $builder->emit( 'local_store', 'void', [ $i_s, $builder->emit( 'add', 'i64', [ $i, 1 ] ) ] );
        $builder->emit_jump($l_loop);
        $builder->emit_label($l_done);
        $builder->emit( 'intrinsic_print_char', 'void', [$close] );
        $builder->emit( 'shadow_pop',           'void', [] );
    }

    method _emit_runtime_dump_hash( $val_s, $indent_s ) {
        my $val = $builder->emit( 'local_load', 'ptr', [$val_s] );
        $builder->emit( 'shadow_push',          'void', [$val] );
        $builder->emit( 'intrinsic_print_char', 'void', [ ord('{') ] );
        my $keys_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $keys_s, $builder->emit( 'call_func', 'ptr', [ 'M_hash_keys', $val ] ) ] );
        my $keys = $builder->emit( 'local_load', 'ptr', [$keys_s] );
        $builder->emit( 'shadow_push', 'void', [$keys] );
        my $qword = $builder->emit( 'load_mem_disp', 'i64', [ $keys,  0 ] );
        my $count = $builder->emit( 'shr',           'i64', [ $qword, 2 ] );
        my $i_s   = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $i_s, 0 ] );
        my $l_loop = $builder->new_label();
        my $l_done = $builder->new_label();
        $builder->emit_label($l_loop);
        my $i = $builder->emit( 'local_load', 'i64', [$i_s] );
        $builder->emit_cond_br( $builder->emit( 'cmp_ge', 'Int', [ $i, $count ] ), $l_done, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        my $l_no_comma = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $i, 0 ] ), $l_no_comma, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        $builder->emit( 'intrinsic_print', 'void', [ $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string(", ") ] ) ] );
        $builder->emit_label($l_no_comma);
        my $curr_keys = $builder->emit( 'local_load', 'ptr', [$keys_s] );
        my $key_ptr
            = $builder->emit( 'add', 'ptr', [ $curr_keys, $builder->emit( 'add', 'i64', [ 8, $builder->emit( 'mul', 'i64', [ $i, 8 ] ) ] ) ] );
        my $key         = $builder->emit( 'load_mem_disp', 'i64', [ $key_ptr, 0 ] );
        my $next_indent = $builder->emit( 'add', 'i64', [ $builder->emit( 'local_load', 'i64', [$indent_s] ), 2 ] );
        $builder->emit( 'call_func', 'void', [ 'M_dump_recursive', $key, $next_indent ] );
        $builder->emit( 'intrinsic_print', 'void', [ $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string(": ") ] ) ] );
        my $curr_hash = $builder->emit( 'local_load', 'ptr', [$val_s] );
        my $value     = $builder->emit( 'call_func',  'Any', [ 'M_hash_lookup', $curr_hash, $key ] );
        $builder->emit( 'call_func', 'void', [ 'M_dump_recursive', $value, $next_indent ] );
        $builder->emit( 'local_store', 'void', [ $i_s, $builder->emit( 'add', 'i64', [ $i, 1 ] ) ] );
        $builder->emit_jump($l_loop);
        $builder->emit_label($l_done);
        $builder->emit( 'intrinsic_print_char', 'void', [ ord('}') ] );
        $builder->emit( 'shadow_pop',           'void', [] );
        $builder->emit( 'shadow_pop',           'void', [] );
    }

    method inject_runtime_new_fiber() {
        $driver->reset_locals();
        $builder->emit_label('M_fiber_new');
        $builder->emit( 'enter_func', 'void', [] );
        my $fp_slot = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $fp_slot, $builder->emit( 'get_arg', 'i64', [0] ) ] );
        my $fcb_slot = $driver->alloc_local_slot();
        $builder->emit(
            'local_store',
            'void',
            [   $fcb_slot,
                $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', $builder->emit( 'constant', 'i64', [ 64 | hex("C000000000000000") ] ) ] )
            ]
        );
        $builder->emit( 'shadow_push', 'void', [ $builder->emit( 'local_load', 'ptr', [$fcb_slot] ) ] );
        $builder->emit( 'store_mem_disp', 'void',
            [ $builder->emit( 'local_load', 'ptr', [$fcb_slot] ), 56, $builder->emit( 'intrinsic_create_wait_handle', 'ptr', [] ) ] );
        my $sm = $builder->emit( 'intrinsic_alloc', 'ptr', [2097152] );
        my $tp = $builder->emit( 'and', 'i64',
            [ $builder->emit( 'add', 'ptr', [ $sm, 2097152 ] ), $builder->emit( 'constant', 'i64', [ hex("FFFFFFFFFFFFFFF0") ] ) ] );
        my $rs = $builder->emit( 'sub', 'ptr', [ $tp, ( $driver->arch eq 'x64' ? 48 : 0 ) ] );
        $builder->emit( 'store_mem_disp', 'void', [ $rs, 0, $builder->emit( 'local_load', 'i64', [$fp_slot] ) ] );
        $builder->emit( 'store_mem_disp', 'void',
            [ $builder->emit( 'local_load', 'ptr', [$fcb_slot] ), 0, $builder->emit( 'sub', 'ptr', [ $rs, $driver->context_size() ] ) ] );
        $builder->emit( 'store_mem_disp', 'void', [ $builder->emit( 'local_load', 'ptr', [$fcb_slot] ), 8, $tp ] );
        my $sh = $builder->emit( 'intrinsic_alloc', 'ptr', [1048576] );
        $builder->emit( 'store_mem_disp', 'void', [ $builder->emit( 'local_load', 'ptr', [$fcb_slot] ), 24, $sh ] );
        $builder->emit( 'store_mem_disp', 'void', [ $builder->emit( 'local_load', 'ptr', [$fcb_slot] ), 32, $sh ] );
        my $is = $builder->emit( 'get_isolate_ctx', 'ptr', [] );
        $builder->emit(
            'store_mem_disp',
            'void',
            [   $builder->emit( 'local_load', 'ptr', [$fcb_slot] ),
                $driver->fcb_offset('next'),
                $builder->emit( 'load_mem_disp', 'ptr', [ $is, $driver->iso_offset('fiber_head') ] )
            ]
        );
        $builder->emit( 'store_mem_disp', 'void', [ $is, $driver->iso_offset('fiber_head'), $builder->emit( 'local_load', 'ptr', [$fcb_slot] ) ] );
        $builder->emit( 'shadow_pop',     'void', [] );
        $builder->emit( 'leave_func',     'void', [ $builder->emit( 'local_load', 'ptr', [$fcb_slot] ) ] );
    }

    method inject_runtime_concat() {
        $driver->reset_locals();
        $builder->emit_label('M_concat');
        $builder->emit( 'enter_func', 'void', [] );
        my $s1_slot = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $s1_slot, $builder->emit( 'get_arg', 'ptr', [0] ) ] );
        my $s2_slot = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $s2_slot, $builder->emit( 'get_arg', 'ptr', [1] ) ] );
        $builder->emit( 'shadow_push', 'void', [ $builder->emit( 'local_load', 'ptr', [$s1_slot] ) ] );
        $builder->emit( 'shadow_push', 'void', [ $builder->emit( 'local_load', 'ptr', [$s2_slot] ) ] );
        my $l1_slot = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void',
            [ $l1_slot, $builder->emit( 'load_mem_disp', 'i64', [ $builder->emit( 'local_load', 'ptr', [$s1_slot] ), 0 ] ) ] );
        my $l2_slot = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void',
            [ $l2_slot, $builder->emit( 'load_mem_disp', 'i64', [ $builder->emit( 'local_load', 'ptr', [$s2_slot] ), 0 ] ) ] );
        my $tl_slot = $driver->alloc_local_slot();
        $builder->emit(
            'local_store',
            'void',
            [   $tl_slot,
                $builder->emit(
                    'add', 'i64', [ $builder->emit( 'local_load', 'i64', [$l1_slot] ), $builder->emit( 'local_load', 'i64', [$l2_slot] ) ]
                )
            ]
        );
        my $ns_slot = $driver->alloc_local_slot();
        $builder->emit(
            'local_store',
            'void',
            [   $ns_slot,
                $builder->emit(
                    'call_func',
                    'ptr',
                    [   'M_gc_alloc',
                        $builder->emit(
                            'or', 'i64',
                            [   $builder->emit( 'add',      'i64', [ $builder->emit( 'local_load', 'i64', [$tl_slot] ), 16 ] ),
                                $builder->emit( 'constant', 'i64', [ hex("C000000000000000") ] )
                            ]
                        )
                    ]
                )
            ]
        );
        $builder->emit( 'shadow_push', 'void', [ $builder->emit( 'local_load', 'ptr', [$ns_slot] ) ] );
        $builder->emit( 'store_mem_disp', 'void',
            [ $builder->emit( 'local_load', 'ptr', [$ns_slot] ), 0, $builder->emit( 'local_load', 'i64', [$tl_slot] ) ] );
        my $i_slot = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $i_slot, 0 ] );
        my $l1s = $builder->new_label();
        my $l1e = $builder->new_label();
        $builder->emit_label($l1s);
        my $ci       = $builder->emit( 'local_load', 'i64', [$i_slot] );
        my $l1s_body = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_lt', 'Int', [ $ci, $builder->emit( 'local_load', 'i64', [$l1_slot] ) ] ), $l1s_body, $l1e );
        $builder->emit_label($l1s_body);
        $builder->emit(
            'store_mem_byte',
            'void',
            [   $builder->emit( 'local_load', 'ptr', [$ns_slot] ),
                $builder->emit( 'add',        'i64', [ $ci, 16 ] ),
                $builder->emit(
                    'load_mem_byte', 'i64', [ $builder->emit( 'local_load', 'ptr', [$s1_slot] ), $builder->emit( 'add', 'i64', [ $ci, 16 ] ) ]
                )
            ]
        );
        $builder->emit( 'local_store', 'void', [ $i_slot, $builder->emit( 'add', 'i64', [ $ci, 1 ] ) ] );
        $builder->emit_jump($l1s);
        $builder->emit_label($l1e);
        $builder->emit( 'local_store', 'void', [ $i_slot, 0 ] );
        my $l2s = $builder->new_label();
        my $l2e = $builder->new_label();
        $builder->emit_label($l2s);
        my $cj       = $builder->emit( 'local_load', 'i64', [$i_slot] );
        my $l2s_body = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_lt', 'Int', [ $cj, $builder->emit( 'local_load', 'i64', [$l2_slot] ) ] ), $l2s_body, $l2e );
        $builder->emit_label($l2s_body);
        $builder->emit(
            'store_mem_byte',
            'void',
            [   $builder->emit( 'local_load', 'ptr', [$ns_slot] ),
                $builder->emit( 'add', 'i64', [ $builder->emit( 'add', 'i64', [ $cj, 16 ] ), $builder->emit( 'local_load', 'i64', [$l1_slot] ) ] ),
                $builder->emit(
                    'load_mem_byte', 'i64', [ $builder->emit( 'local_load', 'ptr', [$s2_slot] ), $builder->emit( 'add', 'i64', [ $cj, 16 ] ) ]
                )
            ]
        );
        $builder->emit( 'local_store', 'void', [ $i_slot, $builder->emit( 'add', 'i64', [ $cj, 1 ] ) ] );
        $builder->emit_jump($l2s);
        $builder->emit_label($l2e);
        $builder->emit( 'shadow_pop', 'void', [] );
        $builder->emit( 'shadow_pop', 'void', [] );
        $builder->emit( 'shadow_pop', 'void', [] );
        $builder->emit( 'leave_func', 'void', [ $builder->emit( 'local_load', 'ptr', [$ns_slot] ) ] );
    }

    method inject_runtime_to_string() {
        $driver->reset_locals();
        $builder->emit_label('M_any_to_str');
        $builder->emit( 'enter_func', 'void', [] );
        my $v_slot = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $v_slot, $builder->emit( 'get_arg', 'i64', [0] ) ] );
        my $v           = $builder->emit( 'local_load', 'i64', [$v_slot] );
        my $l_undef     = $builder->new_label();
        my $l_not_undef = $builder->new_label();
        my $uptr        = $builder->emit( 'load_data_addr', 'ptr', [$undef_ptr_offset] );
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $v, $uptr ] ), $l_undef, $l_not_undef );
        $builder->emit_label($l_undef);
        $builder->emit( 'leave_func', 'void', [ $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string("undef") ] ) ] );
        $builder->emit_label($l_not_undef);
        my $l_t1 = $builder->new_label();
        my $l_f1 = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'and', 'i64', [ $builder->emit( 'local_load', 'i64', [$v_slot] ), 1 ] ), $l_t1, $l_f1 );

        # --- Non-integer branch (Pointer) ---
        $builder->emit_label($l_f1);
        my $ptr_val        = $builder->emit( 'local_load', 'ptr', [$v_slot] );
        my $l_ptr_not_null = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_ne', 'Int', [ $ptr_val, 0 ] ), $l_ptr_not_null, $l_undef );
        $builder->emit_label($l_ptr_not_null);
        my $hdr       = $builder->emit( 'load_mem_disp', 'i64', [ $ptr_val, -8 ] );
        my $is_leaf   = $builder->emit( 'cmp_eq', 'Int', [ $builder->emit( 'shr', 'i64', [ $hdr, 62 ] ), 3 ] );
        my $l_is_leaf = $builder->new_label();
        my $l_not_str = $builder->new_label();
        $builder->emit_cond_br( $is_leaf, $l_is_leaf, $l_not_str );

        # --- Leaf Branch (String or Special Box) ---
        $builder->emit_label($l_is_leaf);
        my $is_special = $builder->emit( 'and', 'i64', [ $hdr, $builder->emit( 'constant', 'i64', [ 1 << 61 ] ) ] );
        my $l_special  = $builder->new_label();
        my $l_is_str   = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_ne', 'Int', [ $is_special, 0 ] ), $l_special, $l_is_str );

        # 1. String: already a string, return directly
        $builder->emit_label($l_is_str);
        $builder->emit( 'leave_func', 'void', [$ptr_val] );

        # 1.1 Special Box (Float, Pointer)
        $builder->emit_label($l_special);
        my $type_id = $builder->emit( 'load_mem_disp', 'i64', [ $ptr_val, 0 ] );
        my $l_f_box = $builder->new_label();
        my $l_p_box = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $type_id, 1 ] ), $l_f_box, $l_p_box );

        # Boxed Float: format to string using our M_float_to_str!
        $builder->emit_label($l_f_box);
        my $f_val_raw = $builder->emit( 'load_mem_disp', 'double', [ $ptr_val, 8 ] );
        my $f_str_obj = $builder->emit( 'call_func',     'ptr',    [ 'M_float_to_str', $f_val_raw ] );
        $builder->emit( 'leave_func', 'ptr', [$f_str_obj] );

        # Boxed Pointer: format to hex
        $builder->emit_label($l_p_box);
        $builder->emit( 'leave_func', 'ptr', [ $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string("[Pointer]") ] ) ] );

        # 2. Non-string heap structures: check first QWORD at +0 for tag bits
        $builder->emit_label($l_not_str);
        my $first      = $builder->emit( 'load_mem_disp', 'i64', [ $ptr_val, 0 ] );
        my $tag_bits   = $builder->emit( 'and',           'i64', [ $first,   3 ] );
        my $l_is_array = $builder->new_label();
        my $l_is_tuple = $builder->new_label();
        my $l_is_hash  = $builder->new_label();
        my $l_is_obj   = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $tag_bits, 1 ] ), $l_is_array, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $tag_bits, 2 ] ), $l_is_tuple, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $tag_bits, 3 ] ), $l_is_hash, $l_is_obj );

        # Array: return count
        $builder->emit_label($l_is_array);
        my $arr_cnt        = $builder->emit( 'shr',       'i64', [ $first, 2 ] );
        my $tagged_arr_cnt = $builder->emit( 'or',        'i64', [ $builder->emit( 'shl', 'i64', [ $arr_cnt, 1 ] ), 1 ] );
        my $arr_cnt_str    = $builder->emit( 'call_func', 'ptr', [ 'M_any_to_str', $tagged_arr_cnt ] );
        $builder->emit( 'leave_func', 'void', [$arr_cnt_str] );

        # Tuple: return count
        $builder->emit_label($l_is_tuple);
        my $tup_cnt        = $builder->emit( 'shr',       'i64', [ $first, 2 ] );
        my $tagged_tup_cnt = $builder->emit( 'or',        'i64', [ $builder->emit( 'shl', 'i64', [ $tup_cnt, 1 ] ), 1 ] );
        my $tup_cnt_str    = $builder->emit( 'call_func', 'ptr', [ 'M_any_to_str', $tagged_tup_cnt ] );
        $builder->emit( 'leave_func', 'void', [$tup_cnt_str] );

        # Hash: return count
        $builder->emit_label($l_is_hash);
        my $hash_cnt        = $builder->emit( 'load_mem_disp', 'i64', [ $ptr_val, 16 ] );
        my $tagged_hash_cnt = $builder->emit( 'or',        'i64', [ $builder->emit( 'shl', 'i64', [ $hash_cnt, 1 ] ), 1 ] );
        my $hash_cnt_str    = $builder->emit( 'call_func', 'ptr', [ 'M_any_to_str', $tagged_hash_cnt ] );
        $builder->emit( 'leave_func', 'void', [$hash_cnt_str] );

        # Class Object: return descriptor
        $builder->emit_label($l_is_obj);
        $builder->emit( 'leave_func', 'void', [ $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string("Object") ] ) ] );

        # --- Integer branch ---
        $builder->emit_label($l_t1);
        my $n    = $builder->emit( 'div', 'i64', [ $builder->emit( 'sub', 'i64', [ $builder->emit( 'local_load', 'i64', [$v_slot] ), 1 ] ), 2 ] );
        my $l_t2 = $builder->new_label();
        my $l_f2 = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $n, 0 ] ), $l_t2, $l_f2 );
        $builder->emit_label($l_t2);
        $builder->emit( 'leave_func', 'void', [ $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string("0") ] ) ] );
        $builder->emit_label($l_f2);
        my $bs = $driver->alloc_local_slot();
        for ( 1 .. 3 ) { $driver->alloc_local_slot() }
        my $buf = $builder->emit( 'sub', 'ptr', [ $builder->emit( 'get_bp', 'ptr', [] ), $bs ] );
        my $is  = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $is, 0 ] );
        my $ns = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $ns, $n ] );
        my $l1 = $builder->new_label();
        my $l2 = $builder->new_label();
        $builder->emit_label($l1);
        my $cn = $builder->emit( 'local_load', 'i64', [$ns] );
        my $ci = $builder->emit( 'local_load', 'i64', [$is] );
        $builder->emit( 'store_mem_byte', 'void',
            [ $buf, $ci, $builder->emit( 'add', 'i64', [ $builder->emit( 'mod', 'i64', [ $cn, 10 ] ), 48 ] ) ] );
        $builder->emit( 'local_store', 'void', [ $is, $builder->emit( 'add', 'i64', [ $ci, 1 ] ) ] );
        my $nn = $builder->emit( 'div', 'i64', [ $cn, 10 ] );
        $builder->emit( 'local_store', 'void', [ $ns, $nn ] );
        $builder->emit_cond_br( $builder->emit( 'cmp_gt', 'Int', [ $nn, 0 ] ), $l1, $l2 );
        $builder->emit_label($l2);
        my $sl_slot = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $sl_slot, $builder->emit( 'local_load', 'i64', [$is] ) ] );
        my $ns_ptr = $builder->emit(
            'call_func',
            'ptr',
            [   'M_gc_alloc',
                $builder->emit(
                    'or', 'i64',
                    [   $builder->emit( 'add',      'i64', [ $builder->emit( 'local_load', 'i64', [$sl_slot] ), 16 ] ),
                        $builder->emit( 'constant', 'i64', [ hex("C000000000000000") ] )
                    ]
                )
            ]
        );
        my $ns_p_slot = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $ns_p_slot, $ns_ptr ] );
        $builder->emit( 'shadow_push', 'void', [ $builder->emit( 'local_load', 'ptr', [$ns_p_slot] ) ] );
        $builder->emit( 'store_mem_disp', 'void',
            [ $builder->emit( 'local_load', 'ptr', [$ns_p_slot] ), 0, $builder->emit( 'local_load', 'i64', [$sl_slot] ) ] );
        $builder->emit( 'store_mem_disp', 'void',
            [ $builder->emit( 'local_load', 'ptr', [$ns_p_slot] ), 8, $builder->emit( 'local_load', 'i64', [$sl_slot] ) ] );
        my $cs = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $cs, 0 ] );
        my $l3 = $builder->new_label();
        my $l4 = $builder->new_label();
        $builder->emit_label($l3);
        my $cci  = $builder->emit( 'local_load', 'i64', [$cs] );
        my $l_f3 = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_ge', 'Int', [ $cci, $builder->emit( 'local_load', 'i64', [$sl_slot] ) ] ), $l4, $l_f3 );
        $builder->emit_label($l_f3);
        $builder->emit(
            'store_mem_byte',
            'void',
            [   $builder->emit( 'local_load', 'ptr', [$ns_p_slot] ),
                $builder->emit( 'add',        'i64', [ $cci, 16 ] ),
                $builder->emit(
                    'load_mem_byte',
                    'i64',
                    [   $buf,
                        $builder->emit(
                            'sub', 'i64', [ $builder->emit( 'sub', 'i64', [ $builder->emit( 'local_load', 'i64', [$sl_slot] ), 1 ] ), $cci ]
                        )
                    ]
                )
            ]
        );
        $builder->emit( 'local_store', 'void', [ $cs, $builder->emit( 'add', 'i64', [ $cci, 1 ] ) ] );
        $builder->emit_jump($l3);
        $builder->emit_label($l4);
        $builder->emit( 'shadow_pop', 'void', [] );
        $builder->emit( 'leave_func', 'ptr',  [ $builder->emit( 'local_load', 'ptr', [$ns_p_slot] ) ] );
    }

    method _trace($msg) {
        return unless $driver->debug >= 4;
        $builder->emit( 'intrinsic_print_stderr', 'void', [ $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string($msg) ] ) ] );
    }

    method _trace_reg( $msg, $reg ) {
        return unless $driver->debug >= 4;
        $self->_trace($msg);
        $builder->emit( 'call_func', 'void', [ 'M_print_int', $builder->emit( 'or', 'i64', [ $reg, 1 ] ) ] );
        $self->_trace("\n");
    }

    method _emit_runtime_init_sub() {
        $builder->emit_label('M_runtime_init');
        $builder->emit( 'enter_func', 'void', [] );
        $self->_trace("M_runtime_init enter\n");
        my $giso_ptr     = $builder->emit( 'load_data_addr', 'ptr', [ $driver->global_iso_offset ] );
        my $l_done       = $builder->new_label();
        my $l_init       = $builder->new_label();
        my $existing_iso = $builder->emit( 'load_mem_disp', 'i64', [ $giso_ptr, 0 ] );
        $builder->emit_cond_br( $builder->emit( 'cmp_ne', 'Int', [ $existing_iso, 0 ] ), $l_done, $l_init );
        $builder->emit_label($l_init);
        my $iso = $builder->emit( 'intrinsic_alloc', 'ptr', [1024] );
        $self->_trace("M_runtime_init: alloc 1024 ok\n");
        $builder->emit( 'set_isolate_ctx', 'void', [$iso] );
        $builder->emit( 'store_mem_disp',  'void', [ $giso_ptr, 0, $iso ] );
        my $extab_off_ptr = $builder->emit( 'load_data_addr', 'ptr', [ $driver->exception_table_offset ] );
        my $extab_off     = $builder->emit( 'load_mem_disp',  'i64', [ $extab_off_ptr, 0 ] );
        my $data_base     = $builder->emit( 'load_data_addr', 'ptr', [0] );
        my $extab_ptr     = $builder->emit( 'add',            'ptr', [ $data_base, $extab_off ] );
        $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('exception_table'), $extab_ptr ] );
        my $rlt_off_ptr = $builder->emit( 'load_data_addr', 'ptr', [$line_table_ptr_offset] );
        my $rlt_off     = $builder->emit( 'load_mem_disp',  'i64', [ $rlt_off_ptr, 0 ] );
        my $rlt_ptr     = $builder->emit( 'add',            'ptr', [ $data_base,   $rlt_off ] );
        $builder->emit( 'store_mem_disp', 'void', [ $rlt_off_ptr, 0, $rlt_ptr ] );
        my $ms = $builder->emit( 'intrinsic_alloc', 'ptr', [1048576] );
        $self->_trace("M_runtime_init: alloc 1MB ok\n");
        $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('mark_stack_base'),  $ms ] );
        $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('mark_stack_ptr'),   $ms ] );
        $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('mark_stack_limit'), $builder->emit( 'add', 'ptr', [ $ms, 1048576 ] ) ] );

        # --- Generational Nursery Initialization (64KB) ---
        my $raw_nursery = $builder->emit( 'intrinsic_alloc', 'ptr', [65536] );
        $self->_trace("M_runtime_init: nursery 64KB ok\n");
        $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('nursery_base'),  $raw_nursery ] );
        $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('nursery_ptr'),   $raw_nursery ] );
        $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('nursery_limit'), $builder->emit( 'add', 'ptr', [ $raw_nursery, 65536 ] ) ] );

        # --- Tenured Heap Initialization (Two 2MB Semi-Spaces) ---
        my $raw_heap = $builder->emit( 'intrinsic_alloc', 'ptr', [4259840] );    # Padded to prevent out-of-bounds on 64KB alignment
        $self->_trace("M_runtime_init: heap ok\n");
        my $mask = $builder->emit( 'constant', 'i64', [ hex("FFFFFFFFFFFF0000") ] );
        my $hp   = $builder->emit( 'and', 'i64', [ $builder->emit( 'add', 'ptr', [ $raw_heap, 65535 ] ), $mask ] );
        $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('heap_base'),  $hp ] );
        $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('heap_ptr'),   $builder->emit( 'add', 'ptr', [ $hp, 1024 ] ) ] );
        $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('heap_limit'), $builder->emit( 'add', 'ptr', [ $hp, 2097152 ] ) ] );

        # Setup ToSpace boundaries at offset 88 and 96
        my $ts_base = $builder->emit( 'add', 'ptr', [ $hp, 2097152 ] );
        $builder->emit( 'store_iso_disp', 'void', [ 88, $ts_base ] );
        $builder->emit( 'store_iso_disp', 'void', [ 96, $builder->emit( 'add', 'ptr', [ $ts_base, 2097152 ] ) ] );

        # --- Heap Block Signature ---
        $builder->emit( 'store_mem_disp', 'void', [ $hp, 8, $builder->emit( 'constant', 'i64', [0x424b4e4845415036] ) ] );
        $self->_trace("M_runtime_init: state table ok\n");
        my $stm = $builder->emit( 'intrinsic_alloc', 'ptr', [1048576] );
        $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('state_ptr'), $stm ] );
        my $fcb = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', $builder->emit( 'constant', 'i64', [ 64 | hex("C000000000000000") ] ) ] );
        $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('current_fcb'), $fcb ] );
        $builder->emit( 'store_mem_disp', 'void', [ $iso, $driver->iso_offset('fiber_head'), $fcb ] );
        my $sh = $builder->emit( 'intrinsic_alloc', 'ptr', [1048576] );
        $self->_trace("M_runtime_init: shadow stack ok\n");
        $builder->emit( 'store_mem_disp', 'void', [ $fcb, $driver->fcb_offset('shadow_base'), $sh ] );
        $builder->emit( 'store_mem_disp', 'void', [ $fcb, $driver->fcb_offset('shadow_ptr'),  $sh ] );
        $builder->emit( 'store_mem_disp', 'void',
            [ $fcb, $driver->fcb_offset('wait_handle'), $builder->emit( 'intrinsic_create_wait_handle', 'ptr', [] ) ] );

        # --- GUARD ALL PROGRAM-LEVEL GLOBALS FOR NON-SHARED LIBRARIES ---
        if ( $driver->type ne 'shared' ) {

            # 1. Instantiate STDOUT (Get standard handle dynamically)
            my $stdout_fd = $builder->emit( 'intrinsic_get_stdout_handle', 'ptr', [] );
            my $stdout_obj
                = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', $builder->emit( 'constant', 'i64', [ 32 | hex("C000000000000000") ] ) ] );
            $builder->emit( 'store_mem_disp', 'void', [ $stdout_obj, 8, $stdout_fd ] );
            $builder->emit( 'store_iso_disp', 'void', [ 176, $stdout_obj ] );

            # 2. Instantiate STDERR (Get standard handle dynamically)
            my $stderr_fd = $builder->emit( 'intrinsic_get_stderr_handle', 'ptr', [] );
            my $stderr_obj
                = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', $builder->emit( 'constant', 'i64', [ 32 | hex("C000000000000000") ] ) ] );
            $builder->emit( 'store_mem_disp', 'void', [ $stderr_obj, 8, $stderr_fd ] );
            $builder->emit( 'store_iso_disp', 'void', [ 184, $stderr_obj ] );

            # 3. Instantiate STDIN (Get standard handle dynamically)
            my $stdin_fd = $builder->emit( 'intrinsic_get_stdin_handle', 'ptr', [] );
            my $stdin_obj
                = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', $builder->emit( 'constant', 'i64', [ 32 | hex("C000000000000000") ] ) ] );
            $builder->emit( 'store_mem_disp', 'void', [ $stdin_obj, 8, $stdin_fd ] );
            $builder->emit( 'store_iso_disp', 'void', [ 192, $stdin_obj ] );

            # 4. Instantiate empty %ENV Hash
            my $env_hash = $builder->emit( 'call_func', 'ptr', ['M_hash_new'] );
            $builder->emit( 'store_iso_disp', 'void', [ 200, $env_hash ] );
            $builder->emit( 'call_func',      'void', ['M_init_env'] );

            # 5. Instantiate empty @ARGV Array
            my $argv_arr = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', $builder->emit( 'constant', 'i64', [8] ) ] );
            $builder->emit( 'store_mem_disp', 'void', [ $argv_arr, 0, $builder->emit( 'constant', 'i64', [1] ) ] );
            $builder->emit( 'store_iso_disp', 'void', [ 208, $argv_arr ] );

            # 6. Instantiate $_ as undef
            my $undef_ptr = $builder->emit( 'load_data_addr', 'ptr', [$undef_ptr_offset] );
            $builder->emit( 'store_iso_disp', 'void', [ 216, $undef_ptr ] );

            # 7. Get current Process ID ($$)
            my $raw_pid    = $builder->emit( 'intrinsic_get_pid', 'i64', [] );
            my $tagged_pid = $builder->emit( 'or', 'i64', [ $builder->emit( 'shl', 'i64', [ $raw_pid, 1 ] ), 1 ] );
            $builder->emit( 'store_iso_disp', 'void', [ 232, $tagged_pid ] );

            # 8. Get executable path ($^X) & Program name ($0)
            my $buf = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', $builder->emit( 'constant', 'i64', [ 512 | hex("C000000000000000") ] ) ] );
            my $len = $builder->emit( 'intrinsic_get_module_filename', 'i64', [$buf] );
            my $exec_path = $builder->emit( 'call_func', 'ptr', [ 'M_str_slice', $buf, $builder->emit( 'constant', 'i64', [0] ), $len ] );
            $builder->emit( 'store_iso_disp', 'void', [ 224, $exec_path ] );    # $^X

            # Settle $0
            my $last_slash = $driver->alloc_local_slot();
            $builder->emit( 'local_store', 'void', [ $last_slash, -1 ] );
            my $i_slot = $driver->alloc_local_slot();
            $builder->emit( 'local_store', 'void', [ $i_slot, 0 ] );
            my $l_slash_loop = $builder->new_label();
            my $l_slash_done = $builder->new_label();
            $builder->emit_label($l_slash_loop);
            my $i = $builder->emit( 'local_load', 'i64', [$i_slot] );
            $builder->emit_cond_br( $builder->emit( 'cmp_ge', 'Int', [ $i, $len ] ), $l_slash_done, $builder->new_label() );
            $builder->emit_label( $builder->last_instruction->{false_l} );
            my $char          = $builder->emit( 'load_mem_byte', 'Int', [ $buf,  $i ] );
            my $is_slash      = $builder->emit( 'cmp_eq',        'Int', [ $char, ord('\\') ] );
            my $l_store_slash = $builder->new_label();
            my $l_skip_slash  = $builder->new_label();
            $builder->emit_cond_br( $is_slash, $l_store_slash, $l_skip_slash );
            $builder->emit_label($l_store_slash);
            $builder->emit( 'local_store', 'void', [ $last_slash, $i ] );
            $builder->emit_label($l_skip_slash);
            $builder->emit( 'local_store', 'void', [ $i_slot, $builder->emit( 'add', 'i64', [ $i, 1 ] ) ] );
            $builder->emit_jump($l_slash_loop);
            $builder->emit_label($l_slash_done);
            my $slash_idx   = $builder->emit( 'local_load', 'i64', [$last_slash] );
            my $l_has_slash = $builder->new_label();
            my $l_no_slash  = $builder->new_label();
            my $l_prog_done = $builder->new_label();
            $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $slash_idx, -1 ] ), $l_no_slash, $l_has_slash );
            $builder->emit_label($l_no_slash);
            $builder->emit( 'store_iso_disp', 'void', [ 240, $exec_path ] );
            $builder->emit_jump($l_prog_done);
            $builder->emit_label($l_has_slash);
            my $start_idx = $builder->emit( 'add',       'i64', [ $slash_idx, 1 ] );
            my $sub_len   = $builder->emit( 'sub',       'i64', [ $builder->emit( 'sub', 'i64', [ $len, $slash_idx ] ), 1 ] );
            my $prog_name = $builder->emit( 'call_func', 'ptr', [ 'M_str_slice', $buf, $start_idx, $sub_len ] );
            $builder->emit( 'store_iso_disp', 'void', [ 240, $prog_name ] );
            $builder->emit_label($l_prog_done);

            # 9. Get Startup Epoch ($^T)
            my $raw_ft = $builder->emit( 'intrinsic_get_system_filetime', 'i64', [] );
            my $epoch  = $builder->emit(
                'div', 'i64',
                [   $builder->emit( 'sub',      'i64', [ $raw_ft, $builder->emit( 'constant', 'i64', [116444736000000000] ) ] ),
                    $builder->emit( 'constant', 'i64', [10000000] )
                ]
            );
            my $tagged_epoch = $builder->emit( 'or', 'i64', [ $builder->emit( 'shl', 'i64', [ $epoch, 1 ] ), 1 ] );
            $builder->emit( 'store_iso_disp', 'void', [ 248, $tagged_epoch ] );

            # 10. Instantiate and Populate @ARGV Array
            $builder->emit( 'call_func', 'void', ['M_init_argv'] );
        }
        $builder->emit_jump($l_done);
        $builder->emit_label($l_done);
        $self->_trace("M_runtime_init complete\n");
        my $active_iso = $builder->emit( 'load_mem_disp', 'i64', [ $giso_ptr, 0 ] );
        $builder->emit( 'set_isolate_ctx', 'void', [$active_iso] );
        my $curr_fcb = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('current_fcb') ] );
        my $bp       = $builder->emit( 'get_bp',        'ptr', [] );
        $builder->emit( 'store_mem_disp', 'void', [ $curr_fcb, $driver->fcb_offset('stack_base'), $bp ] );
        $builder->emit( 'leave_func',     'void', [0] );
    }

    method inject_runtime_str_eq() {
        $driver->reset_locals();
        $builder->emit_label('M_str_eq');
        $builder->emit( 'enter_func', 'void', [] );
        my $s1     = $builder->emit( 'get_arg', 'ptr', [0] );
        my $s2     = $builder->emit( 'get_arg', 'ptr', [1] );
        my $l_diff = $builder->new_label();
        my $l_same = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $s1, $s2 ] ), $l_same, $l_diff );
        $builder->emit_label($l_diff);
        my $l1       = $builder->emit( 'load_mem_disp', 'i64', [ $s1, 0 ] );
        my $l2       = $builder->emit( 'load_mem_disp', 'i64', [ $s2, 0 ] );
        my $l_len_eq = $builder->new_label();
        my $l_fail   = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $l1, $l2 ] ), $l_len_eq, $l_fail );
        $builder->emit_label($l_len_eq);
        my $d1     = $builder->emit( 'add', 'ptr', [ $s1, 16 ] );
        my $d2     = $builder->emit( 'add', 'ptr', [ $s2, 16 ] );
        my $i_slot = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $i_slot, 0 ] );
        my $l_loop = $builder->new_label();
        $builder->emit_label($l_loop);
        my $i      = $builder->emit( 'local_load', 'i64', [$i_slot] );
        my $l_body = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_ge', 'Int', [ $i, $l1 ] ), $l_same, $l_body );
        $builder->emit_label($l_body);
        my $c1     = $builder->emit( 'load_mem_byte', 'Int', [ $d1, $i ] );
        my $c2     = $builder->emit( 'load_mem_byte', 'Int', [ $d2, $i ] );
        my $l_next = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $c1, $c2 ] ), $l_next, $l_fail );
        $builder->emit_label($l_next);
        $builder->emit( 'local_store', 'void', [ $i_slot, $builder->emit( 'add', 'i64', [ $i, 1 ] ) ] );
        $builder->emit_jump($l_loop);
        $builder->emit_label($l_fail);
        $builder->emit( 'leave_func', 'i64', [ $builder->emit( 'constant', 'i64', [0] ) ] );
        $builder->emit_label($l_same);
        $builder->emit( 'leave_func', 'i64', [ $builder->emit( 'constant', 'i64', [1] ) ] );
    }

    method inject_runtime_str_cmp() {
        $driver->reset_locals();
        $builder->emit_label('M_str_cmp');
        $builder->emit( 'enter_func', 'void', [] );
        my $s1     = $builder->emit( 'get_arg', 'ptr', [0] );
        my $s2     = $builder->emit( 'get_arg', 'ptr', [1] );
        my $l_diff = $builder->new_label();
        my $l_same = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $s1, $s2 ] ), $l_same, $l_diff );
        $builder->emit_label($l_diff);
        my $l1           = $builder->emit( 'load_mem_disp', 'i64', [ $s1, 0 ] );
        my $l2           = $builder->emit( 'load_mem_disp', 'i64', [ $s2, 0 ] );
        my $min_len_s    = $driver->alloc_local_slot();
        my $l_l1_smaller = $builder->new_label();
        my $l_l2_smaller = $builder->new_label();
        my $l_len_done   = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_lt', 'Int', [ $l1, $l2 ] ), $l_l1_smaller, $l_l2_smaller );
        $builder->emit_label($l_l1_smaller);
        $builder->emit( 'local_store', 'void', [ $min_len_s, $l1 ] );
        $builder->emit_jump($l_len_done);
        $builder->emit_label($l_l2_smaller);
        $builder->emit( 'local_store', 'void', [ $min_len_s, $l2 ] );
        $builder->emit_label($l_len_done);
        my $d1  = $builder->emit( 'add', 'ptr', [ $s1, 16 ] );
        my $d2  = $builder->emit( 'add', 'ptr', [ $s2, 16 ] );
        my $i_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $i_s, 0 ] );
        my $l_loop = $builder->new_label();
        $builder->emit_label($l_loop);
        my $i           = $builder->emit( 'local_load', 'i64', [$i_s] );
        my $l_check_len = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_ge', 'Int', [ $i, $builder->emit( 'local_load', 'i64', [$min_len_s] ) ] ),
            $l_check_len, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        my $c1       = $builder->emit( 'load_mem_byte', 'Int', [ $d1, $i ] );
        my $c2       = $builder->emit( 'load_mem_byte', 'Int', [ $d2, $i ] );
        my $l_c_diff = $builder->new_label();
        my $l_c_same = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_ne', 'Int', [ $c1, $c2 ] ), $l_c_diff, $l_c_same );
        $builder->emit_label($l_c_diff);
        my $l_c1_less = $builder->new_label();
        my $l_c1_gtr  = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_lt', 'Int', [ $c1, $c2 ] ), $l_c1_less, $l_c1_gtr );
        $builder->emit_label($l_c1_less);
        $builder->emit( 'leave_func', 'i64', [ $builder->emit( 'constant', 'i64', [-1] ) ] );
        $builder->emit_label($l_c1_gtr);
        $builder->emit( 'leave_func', 'i64', [ $builder->emit( 'constant', 'i64', [1] ) ] );
        $builder->emit_label($l_c_same);
        $builder->emit( 'local_store', 'void', [ $i_s, $builder->emit( 'add', 'i64', [ $i, 1 ] ) ] );
        $builder->emit_jump($l_loop);
        $builder->emit_label($l_check_len);
        my $l_len_less = $builder->new_label();
        my $l_len_gtr  = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_lt', 'Int', [ $l1, $l2 ] ), $l_len_less, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        $builder->emit_cond_br( $builder->emit( 'cmp_gt', 'Int', [ $l1, $l2 ] ), $l_len_gtr, $l_same );
        $builder->emit_label($l_len_less);
        $builder->emit( 'leave_func', 'i64', [ $builder->emit( 'constant', 'i64', [-1] ) ] );
        $builder->emit_label($l_len_gtr);
        $builder->emit( 'leave_func', 'i64', [ $builder->emit( 'constant', 'i64', [1] ) ] );
        $builder->emit_label($l_same);
        $builder->emit( 'leave_func', 'i64', [ $builder->emit( 'constant', 'i64', [0] ) ] );
    }

    method inject_runtime_str_slice() {
        $driver->reset_locals();
        $builder->emit_label('M_str_slice');
        $builder->emit( 'enter_func', 'void', [] );
        my $raw_ptr = $builder->emit( 'get_arg', 'ptr', [0] );
        my $start   = $builder->emit( 'get_arg', 'i64', [1] );
        my $len     = $builder->emit( 'get_arg', 'i64', [2] );

        # Pass the Leaf flag and the exact requested payload size to M_gc_alloc
        # M_gc_alloc aligns and computes the full size automatically, writing the proper header.
        my $payload_sz     = $builder->emit( 'add',       'i64', [ $len,        16 ] );
        my $psz_with_flags = $builder->emit( 'or',        'i64', [ $payload_sz, $builder->emit( 'constant', 'i64', [ hex("C000000000000000") ] ) ] );
        my $str            = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', $psz_with_flags ] );
        $builder->emit( 'shadow_push', 'void', [$str] );

        # Store metadata
        $builder->emit( 'store_mem_disp', 'void', [ $str, 0, $len ] );    # Byte len
        $builder->emit( 'store_mem_disp', 'void', [ $str, 8, $len ] );    # Char len

        # Copy bytes
        my $dest_ptr = $builder->emit( 'add', 'ptr', [ $str,     16 ] );
        my $src_ptr  = $builder->emit( 'add', 'ptr', [ $raw_ptr, $start ] );
        my $i_s      = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $i_s, 0 ] );
        my $l_loop = $builder->new_label();
        my $l_end  = $builder->new_label();
        $builder->emit_label($l_loop);
        my $i = $builder->emit( 'local_load', 'i64', [$i_s] );
        $builder->emit_cond_br( $builder->emit( 'cmp_ge', 'Int', [ $i, $len ] ), $l_end, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        my $b = $builder->emit( 'load_mem_byte', 'Int', [ $src_ptr, $i ] );
        $builder->emit( 'store_mem_byte', 'void', [ $dest_ptr, $i, $b ] );
        $builder->emit( 'local_store', 'void', [ $i_s, $builder->emit( 'add', 'i64', [ $i, 1 ] ) ] );
        $builder->emit_jump($l_loop);
        $builder->emit_label($l_end);
        $builder->emit( 'shadow_pop', 'void', [] );
        $builder->emit( 'leave_func', 'ptr',  [$str] );
    }

    method inject_runtime_hash_djb2() {
        $driver->reset_locals();
        $builder->emit_label('M_hash_djb2');
        $builder->emit( 'enter_func', 'void', [] );
        my $str       = $builder->emit( 'get_arg',       'ptr', [0] );
        my $len       = $builder->emit( 'load_mem_disp', 'i64', [ $str, 0 ] );
        my $data_ptr  = $builder->emit( 'add',           'ptr', [ $str, 16 ] );
        my $hash_slot = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $hash_slot, $builder->emit( 'constant', 'i64', [5381] ) ] );
        my $i_slot = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $i_slot, 0 ] );
        my $l_loop = $builder->new_label();
        my $l_end  = $builder->new_label();
        $builder->emit_label($l_loop);
        my $i      = $builder->emit( 'local_load', 'i64', [$i_slot] );
        my $l_body = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_ge', 'Int', [ $i, $len ] ), $l_end, $l_body );
        $builder->emit_label($l_body);
        my $c         = $builder->emit( 'load_mem_byte', 'Int', [ $data_ptr, $i ] );
        my $curr_hash = $builder->emit( 'local_load',    'i64', [$hash_slot] );
        my $h_shl     = $builder->emit( 'shl',           'i64', [ $curr_hash, 5 ] );
        my $h_add     = $builder->emit( 'add',           'i64', [ $h_shl,     $curr_hash ] );
        my $h_new     = $builder->emit( 'add',           'i64', [ $h_add,     $c ] );
        $builder->emit( 'local_store', 'void', [ $hash_slot, $h_new ] );
        $builder->emit( 'local_store', 'void', [ $i_slot,    $builder->emit( 'add', 'i64', [ $i, 1 ] ) ] );
        $builder->emit_jump($l_loop);
        $builder->emit_label($l_end);
        $builder->emit( 'leave_func', 'i64', [ $builder->emit( 'local_load', 'i64', [$hash_slot] ) ] );
    }

    method inject_runtime_hash_new() {
        $driver->reset_locals();
        $builder->emit_label('M_hash_new');
        $builder->emit( 'enter_func', 'void', [] );
        my $hash = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', $builder->emit( 'constant', 'i64', [32] ) ] );
        $builder->emit( 'shadow_push', 'void', [$hash] );
        $builder->emit( 'store_mem_disp', 'void', [ $hash, 0, $builder->emit( 'constant', 'i64', [7] ) ] );
        my $entries = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', $builder->emit( 'constant', 'i64', [136] ) ] );
        $builder->emit( 'store_mem_disp', 'void', [ $entries, 0,  $builder->emit( 'constant', 'i64', [65] ) ] );
        $builder->emit( 'store_mem_disp', 'void', [ $hash,    8,  $entries ] );
        $builder->emit( 'store_mem_disp', 'void', [ $hash,    16, $builder->emit( 'constant', 'i64', [0] ) ] );
        $builder->emit( 'store_mem_disp', 'void', [ $hash,    24, $builder->emit( 'constant', 'i64', [8] ) ] );
        $builder->emit( 'shadow_pop',     'void', [] );
        $builder->emit( 'leave_func',     'ptr',  [$hash] );
    }

    method inject_runtime_hash_lookup_slot() {
        $driver->reset_locals();
        $builder->emit_label('M_hash_lookup_slot');
        $builder->emit( 'enter_func', 'void', [] );
        my $hash_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $hash_s, $builder->emit( 'get_arg', 'ptr', [0] ) ] );
        my $key_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $key_s, $builder->emit( 'get_arg', 'ptr', [1] ) ] );
        my $entries_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void',
            [ $entries_s, $builder->emit( 'load_mem_disp', 'ptr', [ $builder->emit( 'local_load', 'ptr', [$hash_s] ), 8 ] ) ] );
        my $cap    = $builder->emit( 'load_mem_disp', 'i64', [ $builder->emit( 'local_load', 'ptr', [$hash_s] ), 24 ] );
        my $mask_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $mask_s, $builder->emit( 'sub', 'i64', [ $cap, 1 ] ) ] );
        my $h     = $builder->emit( 'call_func', 'i64', [ 'M_hash_djb2', $builder->emit( 'local_load', 'ptr', [$key_s] ) ] );
        my $idx_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $idx_s, $builder->emit( 'and', 'i64', [ $h, $builder->emit( 'local_load', 'i64', [$mask_s] ) ] ) ] );
        my $l_loop = $builder->new_label();
        my $l_fail = $builder->new_label();
        $builder->emit_label($l_loop);
        my $idx     = $builder->emit( 'local_load',    'i64', [$idx_s] );
        my $offset  = $builder->emit( 'mul',           'i64', [ $idx, 16 ] );
        my $entries = $builder->emit( 'local_load',    'ptr', [$entries_s] );
        my $k_addr  = $builder->emit( 'add',           'ptr', [ $builder->emit( 'add', 'ptr', [ $entries, 8 ] ), $offset ] );
        my $k       = $builder->emit( 'load_mem_disp', 'ptr', [ $k_addr, 0 ] );
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $k, 0 ] ), $l_fail, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        my $l_check_eq = $builder->new_label();
        my $l_next     = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $k, 2 ] ), $l_next, $l_check_eq );
        $builder->emit_label($l_check_eq);
        my $is_eq   = $builder->emit( 'call_func', 'i64', [ 'M_str_eq', $k, $builder->emit( 'local_load', 'ptr', [$key_s] ) ] );
        my $l_found = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_ne', 'Int', [ $is_eq, 0 ] ), $l_found, $l_next );
        $builder->emit_label($l_found);
        $builder->emit( 'leave_func', 'ptr', [$k_addr] );
        $builder->emit_label($l_next);
        my $next_idx
            = $builder->emit( 'and', 'i64', [ $builder->emit( 'add', 'i64', [ $idx, 1 ] ), $builder->emit( 'local_load', 'i64', [$mask_s] ) ] );
        $builder->emit( 'local_store', 'void', [ $idx_s, $next_idx ] );
        $builder->emit_jump($l_loop);
        $builder->emit_label($l_fail);
        $builder->emit( 'leave_func', 'ptr', [ $builder->emit( 'constant', 'i64', [0] ) ] );
    }

    method inject_runtime_hash_lookup() {
        $driver->reset_locals();
        $builder->emit_label('M_hash_lookup');
        $builder->emit( 'enter_func', 'void', [] );
        my $hash    = $builder->emit( 'get_arg',   'ptr', [0] );
        my $key     = $builder->emit( 'get_arg',   'ptr', [1] );
        my $slot    = $builder->emit( 'call_func', 'ptr', [ 'M_hash_lookup_slot', $hash, $key ] );
        my $l_fail  = $builder->new_label();
        my $l_found = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $slot, 0 ] ), $l_fail, $l_found );
        $builder->emit_label($l_found);
        my $val = $builder->emit( 'load_mem_disp', 'Any', [ $slot, 8 ] );
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $val, 2 ] ), $l_fail, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        $builder->emit( 'leave_func', 'Any', [$val] );
        $builder->emit_label($l_fail);

        # Return undef pointer
        $builder->emit( 'leave_func', 'Any', [ $builder->emit( 'load_data_addr', 'ptr', [$undef_ptr_offset] ) ] );
    }

    method inject_runtime_hash_exists() {
        $driver->reset_locals();
        $builder->emit_label('M_hash_exists');
        $builder->emit( 'enter_func', 'void', [] );
        my $hash    = $builder->emit( 'get_arg',   'ptr', [0] );
        my $key     = $builder->emit( 'get_arg',   'ptr', [1] );
        my $slot    = $builder->emit( 'call_func', 'ptr', [ 'M_hash_lookup_slot', $hash, $key ] );
        my $l_fail  = $builder->new_label();
        my $l_found = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $slot, 0 ] ), $l_fail, $l_found );
        $builder->emit_label($l_found);
        my $val = $builder->emit( 'load_mem_disp', 'Any', [ $slot, 8 ] );

        # If value is tombstone (2), it doesn't exist
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $val, $builder->emit( 'constant', 'i64', [2] ) ] ),
            $l_fail, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        $builder->emit( 'leave_func', 'i64', [ $builder->emit( 'constant', 'i64', [3] ) ] );
        $builder->emit_label($l_fail);
        $builder->emit( 'leave_func', 'i64', [ $builder->emit( 'constant', 'i64', [1] ) ] );
    }

    method inject_runtime_hash_delete() {
        $driver->reset_locals();
        $builder->emit_label('M_hash_delete');
        $builder->emit( 'enter_func', 'void', [] );
        my $hash    = $builder->emit( 'get_arg',   'ptr', [0] );
        my $key     = $builder->emit( 'get_arg',   'ptr', [1] );
        my $slot    = $builder->emit( 'call_func', 'ptr', [ 'M_hash_lookup_slot', $hash, $key ] );
        my $l_fail  = $builder->new_label();
        my $l_found = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $slot, 0 ] ), $l_fail, $l_found );
        $builder->emit_label($l_found);
        my $val = $builder->emit( 'load_mem_disp', 'Any', [ $slot, 8 ] );
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $val, 2 ] ), $l_fail, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        $builder->emit( 'store_mem_disp', 'void', [ $slot, 8, 2 ] );
        $builder->emit( 'store_mem_disp', 'void', [ $slot, 0, 2 ] );
        my $count = $builder->emit( 'load_mem_disp', 'i64', [ $hash, 16 ] );
        $builder->emit( 'store_mem_disp', 'void', [ $hash, 16, $builder->emit( 'sub', 'i64', [ $count, 1 ] ) ] );
        $builder->emit( 'leave_func', 'Any', [$val] );
        $builder->emit_label($l_fail);
        $builder->emit( 'leave_func', 'Any', [ $builder->emit( 'load_data_addr', 'ptr', [$undef_ptr_offset] ) ] );
    }

    method inject_runtime_hash_insert() {
        $driver->reset_locals();
        $builder->emit_label('M_hash_insert');
        $builder->emit( 'enter_func', 'void', [] );
        my $hash_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $hash_s, $builder->emit( 'get_arg', 'ptr', [0] ) ] );
        my $key_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $key_s, $builder->emit( 'get_arg', 'ptr', [1] ) ] );
        my $val_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $val_s, $builder->emit( 'get_arg', 'Any', [2] ) ] );

        # Load factor check: if (count * 4 >= cap * 3) -> resize
        my $hash        = $builder->emit( 'local_load',    'ptr', [$hash_s] );
        my $count       = $builder->emit( 'load_mem_disp', 'i64', [ $hash,  16 ] );
        my $cap         = $builder->emit( 'load_mem_disp', 'i64', [ $hash,  24 ] );
        my $c4          = $builder->emit( 'mul',           'i64', [ $count, 4 ] );
        my $c3          = $builder->emit( 'mul',           'i64', [ $cap,   3 ] );
        my $l_no_resize = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_ge', 'Int', [ $c4, $c3 ] ), $builder->new_label(), $l_no_resize );
        $builder->emit_label( $builder->last_instruction->{true_l} );
        $builder->emit( 'call_func', 'void', [ 'M_hash_resize', $builder->emit( 'local_load', 'ptr', [$hash_s] ) ] );
        $builder->emit_label($l_no_resize);

        # Proceed with insert
        $hash = $builder->emit( 'local_load', 'ptr', [$hash_s] );    # Reload in case resized
        my $entries_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $entries_s, $builder->emit( 'load_mem_disp', 'ptr', [ $hash, 8 ] ) ] );
        my $mask_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void',
            [ $mask_s, $builder->emit( 'sub', 'i64', [ $builder->emit( 'load_mem_disp', 'i64', [ $hash, 24 ] ), 1 ] ) ] );
        my $h     = $builder->emit( 'call_func', 'i64', [ 'M_hash_djb2', $builder->emit( 'local_load', 'ptr', [$key_s] ) ] );
        my $idx_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $idx_s, $builder->emit( 'and', 'i64', [ $h, $builder->emit( 'local_load', 'i64', [$mask_s] ) ] ) ] );
        my $l_loop   = $builder->new_label();
        my $l_update = $builder->new_label();
        my $l_insert = $builder->new_label();
        $builder->emit_label($l_loop);
        my $idx     = $builder->emit( 'local_load',    'i64', [$idx_s] );
        my $offset  = $builder->emit( 'mul',           'i64', [ $idx, 16 ] );
        my $entries = $builder->emit( 'local_load',    'ptr', [$entries_s] );
        my $k_addr  = $builder->emit( 'add',           'ptr', [ $builder->emit( 'add', 'ptr', [ $entries, 8 ] ), $offset ] );
        my $k       = $builder->emit( 'load_mem_disp', 'ptr', [ $k_addr, 0 ] );
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $k, 0 ] ), $l_insert, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        my $l_check_eq = $builder->new_label();
        my $l_next     = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $k, $builder->emit( 'constant', 'i64', [2] ) ] ), $l_next, $l_check_eq );
        $builder->emit_label($l_check_eq);
        my $is_eq = $builder->emit( 'call_func', 'i64', [ 'M_str_eq', $k, $builder->emit( 'local_load', 'ptr', [$key_s] ) ] );
        $builder->emit_cond_br( $builder->emit( 'cmp_ne', 'Int', [ $is_eq, 0 ] ), $l_update, $l_next );
        $builder->emit_label($l_next);
        my $next_idx
            = $builder->emit( 'and', 'i64', [ $builder->emit( 'add', 'i64', [ $idx, 1 ] ), $builder->emit( 'local_load', 'i64', [$mask_s] ) ] );
        $builder->emit( 'local_store', 'void', [ $idx_s, $next_idx ] );
        $builder->emit_jump($l_loop);
        $builder->emit_label($l_insert);
        $builder->emit( 'store_mem_disp', 'void', [ $k_addr, 0, $builder->emit( 'local_load', 'ptr', [$key_s] ) ] );
        $builder->emit( 'store_mem_disp', 'void', [ $k_addr, 8, $builder->emit( 'local_load', 'Any', [$val_s] ) ] );
        $hash = $builder->emit( 'local_load', 'ptr', [$hash_s] );
        my $cnt = $builder->emit( 'load_mem_disp', 'i64', [ $hash, 16 ] );
        $builder->emit( 'store_mem_disp', 'void', [ $hash, 16, $builder->emit( 'add', 'i64', [ $cnt, 1 ] ) ] );
        $builder->emit( 'leave_func', 'void', [] );
        $builder->emit_label($l_update);
        my $old_v = $builder->emit( 'load_mem_disp', 'Any', [ $k_addr, 8 ] );
        $builder->emit( 'store_mem_disp', 'void', [ $k_addr, 8, $builder->emit( 'local_load', 'Any', [$val_s] ) ] );

        # If the old value was a tombstone, it's a "new" element counting towards load factor
        my $l_was_del  = $builder->new_label();
        my $l_upd_done = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $old_v, $builder->emit( 'constant', 'i64', [2] ) ] ), $l_was_del, $l_upd_done );
        $builder->emit_label($l_was_del);

        # Restore Key on resurrection
        $builder->emit( 'store_mem_disp', 'void', [ $k_addr, 0, $builder->emit( 'local_load', 'ptr', [$key_s] ) ] );
        $hash = $builder->emit( 'local_load', 'ptr', [$hash_s] );
        my $cnt2 = $builder->emit( 'load_mem_disp', 'i64', [ $hash, 16 ] );
        $builder->emit( 'store_mem_disp', 'void', [ $hash, 16, $builder->emit( 'add', 'i64', [ $cnt2, 1 ] ) ] );
        $builder->emit_jump($l_upd_done);
        $builder->emit_label($l_upd_done);
        $builder->emit( 'leave_func', 'void', [] );
    }

    method inject_runtime_hash_resize() {
        $driver->reset_locals();
        $builder->emit_label('M_hash_resize');
        $builder->emit( 'enter_func', 'void', [] );
        my $hash_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $hash_s, $builder->emit( 'get_arg', 'ptr', [0] ) ] );
        my $hash      = $builder->emit( 'local_load', 'ptr', [$hash_s] );
        my $old_ent_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $old_ent_s, $builder->emit( 'load_mem_disp', 'ptr', [ $hash, 8 ] ) ] );
        my $old_cap_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $old_cap_s, $builder->emit( 'load_mem_disp', 'i64', [ $hash, 24 ] ) ] );
        my $new_cap = $builder->emit( 'mul',       'i64', [ $builder->emit( 'local_load', 'i64', [$old_cap_s] ), 2 ] );
        my $new_sz  = $builder->emit( 'add',       'i64', [ $builder->emit( 'mul', 'i64', [ $new_cap, 16 ] ), 8 ] );
        my $new_ent = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', $new_sz ] );

        # Tag: (new_cap * 2) << 2 | 1 == (new_cap << 3) | 1
        my $new_tag = $builder->emit( 'or', 'i64', [ $builder->emit( 'shl', 'i64', [ $new_cap, 3 ] ), 1 ] );
        $builder->emit( 'store_mem_disp', 'void', [ $new_ent, 0, $new_tag ] );
        $hash = $builder->emit( 'local_load', 'ptr', [$hash_s] );
        $builder->emit( 'store_mem_disp', 'void', [ $hash, 8,  $new_ent ] );
        $builder->emit( 'store_mem_disp', 'void', [ $hash, 24, $new_cap ] );
        $builder->emit( 'store_mem_disp', 'void', [ $hash, 16, 0 ] );
        my $i_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $i_s, 0 ] );
        my $l_loop = $builder->new_label();
        my $l_end  = $builder->new_label();
        $builder->emit_label($l_loop);
        my $i = $builder->emit( 'local_load', 'i64', [$i_s] );
        $builder->emit_cond_br( $builder->emit( 'cmp_ge', 'Int', [ $i, $builder->emit( 'local_load', 'i64', [$old_cap_s] ) ] ),
            $l_end, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        my $offset = $builder->emit( 'mul', 'i64', [ $i, 16 ] );
        my $k_addr
            = $builder->emit( 'add', 'ptr', [ $builder->emit( 'add', 'ptr', [ $builder->emit( 'local_load', 'ptr', [$old_ent_s] ), 8 ] ), $offset ] );
        my $k = $builder->emit( 'load_mem_disp', 'ptr', [ $k_addr, 0 ] );
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $k, 0 ] ), $builder->new_label(), $builder->new_label() );
        my $l_skip = $builder->last_instruction->{true_l};
        $builder->emit_label( $builder->last_instruction->{false_l} );

        # Also skip if key is tombstone (2)
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $k, $builder->emit( 'constant', 'i64', [2] ) ] ), $l_skip, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        my $v = $builder->emit( 'load_mem_disp', 'Any', [ $k_addr, 8 ] );

        # Skip if value is tombstone (2) (was deleted)
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $v, $builder->emit( 'constant', 'i64', [2] ) ] ), $l_skip, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        $builder->emit( 'call_func', 'void', [ 'M_hash_insert', $builder->emit( 'local_load', 'ptr', [$hash_s] ), $k, $v ] );
        $builder->emit_label($l_skip);
        $builder->emit( 'local_store', 'void', [ $i_s, $builder->emit( 'add', 'i64', [ $i, 1 ] ) ] );
        $builder->emit_jump($l_loop);
        $builder->emit_label($l_end);
        $builder->emit( 'leave_func', 'void', [] );
    }

    method inject_runtime_hash_keys() {
        $driver->reset_locals();
        $builder->emit_label('M_hash_keys');
        $builder->emit( 'enter_func', 'void', [] );
        my $hash_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $hash_s, $builder->emit( 'get_arg', 'ptr', [0] ) ] );
        my $hash  = $builder->emit( 'local_load',    'ptr', [$hash_s] );
        my $count = $builder->emit( 'load_mem_disp', 'i64', [ $hash, 16 ] );

        # Allocate Array: size = 8 + count * 8
        my $sz  = $builder->emit( 'add', 'i64', [ $builder->emit( 'mul', 'i64', [ $count, 8 ] ), 8 ] );
        my $arr = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', $sz ] );
        $builder->emit( 'shadow_push', 'void', [$arr] );

        # Tag Array: (count << 2) | 1
        my $tag = $builder->emit( 'or', 'i64', [ $builder->emit( 'shl', 'i64', [ $count, 2 ] ), 1 ] );
        $builder->emit( 'store_mem_disp', 'void', [ $arr, 0, $tag ] );
        my $cap     = $builder->emit( 'load_mem_disp', 'i64', [ $hash, 24 ] );
        my $entries = $builder->emit( 'load_mem_disp', 'ptr', [ $hash, 8 ] );
        my $i_s     = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $i_s, 0 ] );
        my $j_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $j_s, 0 ] );
        my $l_loop = $builder->new_label();
        my $l_end  = $builder->new_label();
        $builder->emit_label($l_loop);
        my $i = $builder->emit( 'local_load', 'i64', [$i_s] );
        $builder->emit_cond_br( $builder->emit( 'cmp_ge', 'Int', [ $i, $cap ] ), $l_end, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        my $k_addr = $builder->emit( 'add', 'ptr', [ $builder->emit( 'add', 'ptr', [ $entries, 8 ] ), $builder->emit( 'mul', 'i64', [ $i, 16 ] ) ] );
        my $k      = $builder->emit( 'load_mem_disp', 'ptr', [ $k_addr, 0 ] );
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $k, 0 ] ), $builder->new_label(), $builder->new_label() );
        my $l_skip = $builder->last_instruction->{true_l};
        $builder->emit_label( $builder->last_instruction->{false_l} );

        # Check for key tombstone
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $k, $builder->emit( 'constant', 'i64', [2] ) ] ), $l_skip, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );

        # Check for value tombstone
        my $v = $builder->emit( 'load_mem_disp', 'Any', [ $k_addr, 8 ] );
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $v, $builder->emit( 'constant', 'i64', [2] ) ] ), $l_skip, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        my $j        = $builder->emit( 'local_load', 'i64', [$j_s] );
        my $arr_slot = $builder->emit( 'add', 'ptr', [ $builder->emit( 'add', 'ptr', [ $arr, 8 ] ), $builder->emit( 'mul', 'i64', [ $j, 8 ] ) ] );
        $builder->emit( 'store_mem_disp', 'void', [ $arr_slot, 0, $k ] );
        $builder->emit( 'local_store', 'void', [ $j_s, $builder->emit( 'add', 'i64', [ $j, 1 ] ) ] );
        $builder->emit_label($l_skip);
        $builder->emit( 'local_store', 'void', [ $i_s, $builder->emit( 'add', 'i64', [ $i, 1 ] ) ] );
        $builder->emit_jump($l_loop);
        $builder->emit_label($l_end);
        $builder->emit( 'shadow_pop', 'void', [] );
        $builder->emit( 'leave_func', 'ptr',  [$arr] );
    }

    method inject_runtime_hash_values() {
        $driver->reset_locals();
        $builder->emit_label('M_hash_values');
        $builder->emit( 'enter_func', 'void', [] );
        my $hash_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $hash_s, $builder->emit( 'get_arg', 'ptr', [0] ) ] );
        my $hash  = $builder->emit( 'local_load',    'ptr', [$hash_s] );
        my $count = $builder->emit( 'load_mem_disp', 'i64', [ $hash, 16 ] );

        # Allocate Array: size = 8 + count * 8
        my $sz  = $builder->emit( 'add', 'i64', [ $builder->emit( 'mul', 'i64', [ $count, 8 ] ), 8 ] );
        my $arr = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', $sz ] );
        $builder->emit( 'shadow_push', 'void', [$arr] );

        # Tag Array: (count << 2) | 1
        my $tag = $builder->emit( 'or', 'i64', [ $builder->emit( 'shl', 'i64', [ $count, 2 ] ), 1 ] );
        $builder->emit( 'store_mem_disp', 'void', [ $arr, 0, $tag ] );
        my $cap     = $builder->emit( 'load_mem_disp', 'i64', [ $hash, 24 ] );
        my $entries = $builder->emit( 'load_mem_disp', 'ptr', [ $hash, 8 ] );
        my $i_s     = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $i_s, 0 ] );
        my $j_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $j_s, 0 ] );
        my $l_loop = $builder->new_label();
        my $l_end  = $builder->new_label();
        $builder->emit_label($l_loop);
        my $i = $builder->emit( 'local_load', 'i64', [$i_s] );
        $builder->emit_cond_br( $builder->emit( 'cmp_ge', 'Int', [ $i, $cap ] ), $l_end, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        my $k_addr = $builder->emit( 'add', 'ptr', [ $builder->emit( 'add', 'ptr', [ $entries, 8 ] ), $builder->emit( 'mul', 'i64', [ $i, 16 ] ) ] );
        my $k      = $builder->emit( 'load_mem_disp', 'ptr', [ $k_addr, 0 ] );
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $k, 0 ] ), $builder->new_label(), $builder->new_label() );
        my $l_skip = $builder->last_instruction->{true_l};
        $builder->emit_label( $builder->last_instruction->{false_l} );
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $k, $builder->emit( 'constant', 'i64', [2] ) ] ), $l_skip, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        my $v = $builder->emit( 'load_mem_disp', 'Any', [ $k_addr, 8 ] );
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $v, $builder->emit( 'constant', 'i64', [2] ) ] ), $l_skip, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        my $j        = $builder->emit( 'local_load', 'i64', [$j_s] );
        my $arr_slot = $builder->emit( 'add', 'ptr', [ $builder->emit( 'add', 'ptr', [ $arr, 8 ] ), $builder->emit( 'mul', 'i64', [ $j, 8 ] ) ] );
        $builder->emit( 'store_mem_disp', 'void', [ $arr_slot, 0, $v ] );
        $builder->emit( 'local_store', 'void', [ $j_s, $builder->emit( 'add', 'i64', [ $j, 1 ] ) ] );
        $builder->emit_label($l_skip);
        $builder->emit( 'local_store', 'void', [ $i_s, $builder->emit( 'add', 'i64', [ $i, 1 ] ) ] );
        $builder->emit_jump($l_loop);
        $builder->emit_label($l_end);
        $builder->emit( 'shadow_pop', 'void', [] );
        $builder->emit( 'leave_func', 'ptr',  [$arr] );
    }

    method inject_runtime_init_env() {
        if ( $driver->os eq 'win64' ) {
            $self->inject_runtime_init_env_win64();
        }
        else {
            $self->inject_runtime_init_env_unix();
        }
    }

    method inject_runtime_init_env_win64() {
        $driver->reset_locals();
        $builder->emit_label('M_init_env');
        $builder->emit( 'enter_func', 'void', [] );

        # --- FIX: Allocate a proper local stack slot ---
        my $env_hash_slot = $driver->alloc_local_slot();
        my $env_hash      = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('env_hash') ] );
        $builder->emit( 'local_store', 'void', [ $env_hash_slot, $env_hash ] );
        $builder->emit( 'shadow_push', 'void', [$env_hash] );

        # Win32 block lookup
        my $block_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $block_s, $builder->emit( 'intrinsic_get_env_block', 'ptr', [] ) ] );
        my $cursor_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $cursor_s, 0 ] );
        my $l_block_loop = $builder->new_label();
        my $l_block_done = $builder->new_label();
        my $l_block_null = $builder->new_label();
        $builder->emit_label($l_block_loop);
        my $block = $builder->emit( 'local_load', 'ptr', [$block_s] );

        # --- Guard against NULL environment block pointer ---
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $block, 0 ] ), $l_block_null, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        my $cursor = $builder->emit( 'local_load', 'i64', [$cursor_s] );

        # Check if double null (end of environment block)
        my $char0 = $builder->emit( 'load_mem_byte', 'Int', [ $block, $cursor ] );
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $char0, 0 ] ), $l_block_done, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );

        # Parse individual "Key=Value" string starting at $cursor
        my $eq_idx_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $eq_idx_s, -1 ] );
        my $len_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $len_s, 0 ] );
        my $l_scan_loop = $builder->new_label();
        my $l_scan_done = $builder->new_label();
        $builder->emit_label($l_scan_loop);
        my $len      = $builder->emit( 'local_load',    'i64', [$len_s] );
        my $scan_idx = $builder->emit( 'add',           'i64', [ $cursor, $len ] );
        my $b        = $builder->emit( 'load_mem_byte', 'Int', [ $block,  $scan_idx ] );
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $b, 0 ] ), $l_scan_done, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );

        # If b == '=', record index of '='
        my $l_is_eq  = $builder->new_label();
        my $l_not_eq = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $b, ord('=') ] ), $l_is_eq, $l_not_eq );
        $builder->emit_label($l_is_eq);
        $builder->emit( 'local_store', 'void', [ $eq_idx_s, $len ] );
        $builder->emit_label($l_not_eq);
        $builder->emit( 'local_store', 'void', [ $len_s, $builder->emit( 'add', 'i64', [ $len, 1 ] ) ] );
        $builder->emit_jump($l_scan_loop);
        $builder->emit_label($l_scan_done);

        # We finished scanning the "Key=Value" string.
        my $eq_idx    = $builder->emit( 'local_load', 'i64', [$eq_idx_s] );
        my $total_len = $builder->emit( 'local_load', 'i64', [$len_s] );

        # Only slice and insert if we actually found '='
        my $l_insert_kv = $builder->new_label();
        my $l_skip_kv   = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_ne', 'Int', [ $eq_idx, -1 ] ), $l_insert_kv, $l_skip_kv );
        $builder->emit_label($l_insert_kv);

        # Slice Key: [cursor, eq_idx]
        my $key_obj = $builder->emit( 'call_func', 'ptr', [ 'M_str_slice', $block, $cursor, $eq_idx ] );
        $builder->emit( 'shadow_push', 'void', [$key_obj] );

        # Slice Value: [cursor + eq_idx + 1, total_len - eq_idx - 1]
        my $val_start = $builder->emit( 'add',       'i64', [ $builder->emit( 'add', 'i64', [ $cursor,    $eq_idx ] ), 1 ] );
        my $val_len   = $builder->emit( 'sub',       'i64', [ $builder->emit( 'sub', 'i64', [ $total_len, $eq_idx ] ), 1 ] );
        my $val_obj   = $builder->emit( 'call_func', 'ptr', [ 'M_str_slice', $block, $val_start, $val_len ] );

        # Insert into %ENV (Using env_hash_slot now!)
        $builder->emit( 'call_func',  'void', [ 'M_hash_insert', $builder->emit( 'local_load', 'ptr', [$env_hash_slot] ), $key_obj, $val_obj ] );
        $builder->emit( 'shadow_pop', 'void', [] );    # pop key_obj
        $builder->emit_label($l_skip_kv);

        # Advance cursor past the null-terminator of "Key=Value\0"
        $builder->emit( 'local_store', 'void',
            [ $cursor_s, $builder->emit( 'add', 'i64', [ $builder->emit( 'add', 'i64', [ $cursor, $total_len ] ), 1 ] ) ] );
        $builder->emit_jump($l_block_loop);
        $builder->emit_label($l_block_done);
        $builder->emit( 'intrinsic_free_env_block', 'void', [$block] );
        $builder->emit_label($l_block_null);
        $builder->emit( 'shadow_pop', 'void', [] );    # pop env_hash
        $builder->emit( 'leave_func', 'void', [] );
    }

    method inject_runtime_init_env_unix() {
        $driver->reset_locals();
        $builder->emit_label('M_init_env');
        $builder->emit( 'enter_func', 'void', [] );
        my $env_hash_slot = $driver->alloc_local_slot();
        my $env_hash      = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('env_hash') ] );
        $builder->emit( 'local_store', 'void', [ $env_hash_slot, $env_hash ] );
        $builder->emit( 'shadow_push', 'void', [$env_hash] );
        my $envp_ptr_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $envp_ptr_s, $builder->emit( 'intrinsic_get_unix_envp', 'ptr', [$stack_ptr_offset] ) ] );
        my $l_loop = $builder->new_label();
        my $l_done = $builder->new_label();
        $builder->emit_label($l_loop);
        my $envp_ptr = $builder->emit( 'local_load',    'ptr', [$envp_ptr_s] );
        my $env_str  = $builder->emit( 'load_mem_disp', 'ptr', [ $envp_ptr, 0 ] );

        # If env_str == NULL, we are done
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $env_str, 0 ] ), $l_done, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );

        # We have a valid env_str. Now parse "Key=Value"
        my $eq_idx_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $eq_idx_s, -1 ] );
        my $len_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $len_s, 0 ] );
        my $l_scan_loop = $builder->new_label();
        my $l_scan_done = $builder->new_label();
        $builder->emit_label($l_scan_loop);
        my $len = $builder->emit( 'local_load',    'i64', [$len_s] );
        my $b   = $builder->emit( 'load_mem_byte', 'Int', [ $env_str, $len ] );
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $b, 0 ] ), $l_scan_done, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );

        # If b == '=', record index of '='
        my $l_is_eq  = $builder->new_label();
        my $l_not_eq = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $b, ord('=') ] ), $l_is_eq, $l_not_eq );
        $builder->emit_label($l_is_eq);
        $builder->emit( 'local_store', 'void', [ $eq_idx_s, $len ] );
        $builder->emit_label($l_not_eq);
        $builder->emit( 'local_store', 'void', [ $len_s, $builder->emit( 'add', 'i64', [ $len, 1 ] ) ] );
        $builder->emit_jump($l_scan_loop);
        $builder->emit_label($l_scan_done);

        # We finished scanning the "Key=Value" string
        my $eq_idx    = $builder->emit( 'local_load', 'i64', [$eq_idx_s] );
        my $total_len = $builder->emit( 'local_load', 'i64', [$len_s] );

        # Only slice and insert if we actually found '='
        my $l_insert_kv = $builder->new_label();
        my $l_skip_kv   = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_ne', 'Int', [ $eq_idx, -1 ] ), $l_insert_kv, $l_skip_kv );
        $builder->emit_label($l_insert_kv);

        # Slice Key: [0, eq_idx]
        my $key_obj = $builder->emit( 'call_func', 'ptr', [ 'M_str_slice', $env_str, 0, $eq_idx ] );
        $builder->emit( 'shadow_push', 'void', [$key_obj] );

        # Slice Value: [eq_idx + 1, total_len - eq_idx - 1]
        my $val_start = $builder->emit( 'add',       'i64', [ $eq_idx, 1 ] );
        my $val_len   = $builder->emit( 'sub',       'i64', [ $builder->emit( 'sub', 'i64', [ $total_len, $eq_idx ] ), 1 ] );
        my $val_obj   = $builder->emit( 'call_func', 'ptr', [ 'M_str_slice', $env_str, $val_start, $val_len ] );

        # Insert into %ENV
        $builder->emit( 'call_func',  'void', [ 'M_hash_insert', $builder->emit( 'local_load', 'ptr', [$env_hash_slot] ), $key_obj, $val_obj ] );
        $builder->emit( 'shadow_pop', 'void', [] );    # pop key_obj
        $builder->emit_label($l_skip_kv);

        # Advance envp_ptr to the next string: envp_ptr += 8
        $builder->emit( 'local_store', 'void', [ $envp_ptr_s, $builder->emit( 'add', 'ptr', [ $envp_ptr, 8 ] ) ] );
        $builder->emit_jump($l_loop);
        $builder->emit_label($l_done);
        $builder->emit( 'shadow_pop', 'void', [] );    # pop env_hash
        $builder->emit( 'leave_func', 'void', [] );
    }

    method inject_runtime_init_argv() {
        if ( $driver->os eq 'win64' ) {
            $self->inject_runtime_init_argv_win64();
        }
        else {
            $self->inject_runtime_init_argv_unix();
        }
    }

    method inject_runtime_init_argv_win64() {
        $driver->reset_locals();
        $builder->emit_label('M_init_argv');
        $builder->emit( 'enter_func', 'void', [] );
        my $argv_s      = $driver->alloc_local_slot();
        my $cursor_s    = $driver->alloc_local_slot();
        my $start_s     = $driver->alloc_local_slot();
        my $in_q_s      = $driver->alloc_local_slot();
        my $argc_s      = $driver->alloc_local_slot();
        my $cp_i_s      = $driver->alloc_local_slot();
        my $tmp_start_s = $driver->alloc_local_slot();
        my $tmp_len_s   = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $argv_s, $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('argv_array') ] ) ] );
        $builder->emit( 'shadow_push', 'void', [ $builder->emit( 'local_load', 'ptr', [$argv_s] ) ] );
        my $cmd = $builder->emit( 'intrinsic_get_cmd_line', 'ptr', [] );
        $builder->emit( 'local_store', 'void', [ $cursor_s, 0 ] );
        $builder->emit( 'local_store', 'void', [ $start_s,  0 ] );
        $builder->emit( 'local_store', 'void', [ $in_q_s,   0 ] );
        $builder->emit( 'local_store', 'void', [ $argc_s,   0 ] );
        my $l_loop = $builder->new_label();
        my $l_end  = $builder->new_label();
        $builder->emit_label($l_loop);
        my $cur   = $builder->emit( 'local_load',    'i64', [$cursor_s] );
        my $b     = $builder->emit( 'load_mem_byte', 'Int', [ $cmd, $cur ] );
        my $in_q  = $builder->emit( 'local_load',    'i64', [$in_q_s] );
        my $start = $builder->emit( 'local_load',    'i64', [$start_s] );

        # Check for double quote to toggle in_q
        my $l_not_quote = $builder->new_label();
        my $is_quote    = $builder->emit( 'cmp_eq', 'Int', [ $b, ord('"') ] );
        $builder->emit_cond_br( $is_quote, $builder->new_label(), $l_not_quote );
        $builder->emit_label( $builder->last_instruction->{true_l} );
        my $new_in_q = $builder->emit( 'xor', 'i64', [ $in_q, 1 ] );
        $builder->emit( 'local_store', 'void', [ $in_q_s, $new_in_q ] );
        $in_q = $new_in_q;    # update in_q for the current char check
        $builder->emit_label($l_not_quote);

        # Check should_split (split on EOF or space outside of quotes)
        my $current_in_q     = $builder->emit( 'local_load', 'i64', [$in_q_s] );
        my $is_eof           = $builder->emit( 'cmp_eq',     'Int', [ $b,            0 ] );
        my $is_space         = $builder->emit( 'cmp_eq',     'Int', [ $b,            ord(' ') ] );
        my $not_in_q         = $builder->emit( 'cmp_eq',     'Int', [ $current_in_q, 0 ] );
        my $is_space_outside = $builder->emit( 'and',        'i64', [ $is_space,     $not_in_q ] );
        my $should_split     = $builder->emit( 'or',         'i64', [ $is_eof,       $is_space_outside ] );
        my $l_split          = $builder->new_label();
        my $l_no_split       = $builder->new_label();
        $builder->emit_cond_br( $should_split, $l_split, $l_no_split );
        $builder->emit_label($l_split);
        my $len         = $builder->emit( 'sub', 'i64', [ $cur, $start ] );
        my $l_push      = $builder->new_label();
        my $l_skip_push = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_gt', 'Int', [ $len, 0 ] ), $l_push, $l_skip_push );
        $builder->emit_label($l_push);
        my $argc          = $builder->emit( 'local_load', 'i64', [$argc_s] );
        my $l_discard_exe = $builder->new_label();
        my $l_store_arg   = $builder->new_label();
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $argc, 0 ] ), $l_discard_exe, $l_store_arg );
        $builder->emit_label($l_discard_exe);
        $builder->emit( 'local_store', 'void', [ $argc_s, 1 ] );
        $builder->emit_jump($l_skip_push);
        $builder->emit_label($l_store_arg);

        # Initialize temp slots for start and len
        $builder->emit( 'local_store', 'void', [ $tmp_start_s, $start ] );
        $builder->emit( 'local_store', 'void', [ $tmp_len_s,   $len ] );

        # Strip outer double quotes if present (standard command-line format)
        my $l_strip_done = $builder->new_label();
        my $first_char   = $builder->emit( 'load_mem_byte', 'Int', [ $cmd, $start ] );
        my $last_idx     = $builder->emit( 'sub',           'i64', [ $builder->emit( 'add', 'i64', [ $start, $len ] ), 1 ] );
        my $last_char    = $builder->emit( 'load_mem_byte', 'Int', [ $cmd,        $last_idx ] );
        my $is_first_q   = $builder->emit( 'cmp_eq',        'Int', [ $first_char, ord('"') ] );
        my $is_last_q    = $builder->emit( 'cmp_eq',        'Int', [ $last_char,  ord('"') ] );
        my $is_both_q    = $builder->emit( 'and',           'i64', [ $is_first_q, $is_last_q ] );
        my $is_len_ok    = $builder->emit( 'cmp_ge',        'Int', [ $len,        2 ] );
        my $should_strip = $builder->emit( 'and',           'i64', [ $is_both_q,  $is_len_ok ] );
        $builder->emit_cond_br( $should_strip, $builder->new_label(), $l_strip_done );
        $builder->emit_label( $builder->last_instruction->{true_l} );
        my $new_start = $builder->emit( 'add', 'i64', [ $start, 1 ] );
        my $new_len   = $builder->emit( 'sub', 'i64', [ $len,   2 ] );
        $builder->emit( 'local_store', 'void', [ $tmp_start_s, $new_start ] );
        $builder->emit( 'local_store', 'void', [ $tmp_len_s,   $new_len ] );
        $builder->emit_jump($l_strip_done);
        $builder->emit_label($l_strip_done);
        my $final_start = $builder->emit( 'local_load', 'i64', [$tmp_start_s] );
        my $final_len   = $builder->emit( 'local_load', 'i64', [$tmp_len_s] );
        my $arg_str     = $builder->emit( 'call_func',  'ptr', [ 'M_str_slice', $cmd, $final_start, $final_len ] );
        $builder->emit( 'shadow_push', 'void', [$arg_str] );

        # Since @ARGV was allocated empty, we'll re-allocate with space!
        my $argv    = $builder->emit( 'local_load', 'ptr', [$argv_s] );
        my $arr_ct  = $builder->emit( 'shr',        'i64', [ $builder->emit( 'load_mem_disp', 'i64', [ $argv, 0 ] ), 2 ] );
        my $new_sz  = $builder->emit( 'add', 'i64', [ $builder->emit( 'mul', 'i64', [ $builder->emit( 'add', 'i64', [ $arr_ct, 1 ] ), 8 ] ), 8 ] );
        my $new_arr = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', $new_sz ] );
        $builder->emit(
            'store_mem_disp',
            'void',
            [   $new_arr, 0,
                $builder->emit( 'or', 'i64', [ $builder->emit( 'shl', 'i64', [ $builder->emit( 'add', 'i64', [ $arr_ct, 1 ] ), 2 ] ), 1 ] )
            ]
        );

        # Copy old elements
        $builder->emit( 'local_store', 'void', [ $cp_i_s, 0 ] );
        my $l_cp_loop = $builder->new_label();
        my $l_cp_end  = $builder->new_label();
        $builder->emit_label($l_cp_loop);
        my $cp_i = $builder->emit( 'local_load', 'i64', [$cp_i_s] );
        $builder->emit_cond_br( $builder->emit( 'cmp_ge', 'Int', [ $cp_i, $arr_ct ] ), $l_cp_end, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        my $src_addr = $builder->emit( 'add', 'ptr', [ $builder->emit( 'add', 'ptr', [ $argv, 8 ] ), $builder->emit( 'mul', 'i64', [ $cp_i, 8 ] ) ] );
        my $el       = $builder->emit( 'load_mem_disp', 'Any', [ $src_addr, 0 ] );
        my $dst_addr
            = $builder->emit( 'add', 'ptr', [ $builder->emit( 'add', 'ptr', [ $new_arr, 8 ] ), $builder->emit( 'mul', 'i64', [ $cp_i, 8 ] ) ] );
        $builder->emit( 'store_mem_disp', 'void', [ $dst_addr, 0, $el ] );
        $builder->emit( 'local_store', 'void', [ $cp_i_s, $builder->emit( 'add', 'i64', [ $cp_i, 1 ] ) ] );
        $builder->emit_jump($l_cp_loop);
        $builder->emit_label($l_cp_end);
        my $append_addr
            = $builder->emit( 'add', 'ptr', [ $builder->emit( 'add', 'ptr', [ $new_arr, 8 ] ), $builder->emit( 'mul', 'i64', [ $arr_ct, 8 ] ) ] );
        $builder->emit( 'store_mem_disp', 'void', [ $append_addr, 0, $arg_str ] );
        $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('argv_array'), $new_arr ] );
        $builder->emit( 'local_store',    'void', [ $argv_s, $new_arr ] );
        $builder->emit( 'shadow_pop',     'void', [] );    # pop arg_str
        $builder->emit_label($l_skip_push);
        $builder->emit( 'local_store', 'void', [ $start_s, $builder->emit( 'add', 'i64', [ $cur, 1 ] ) ] );
        $builder->emit_jump($l_no_split);
        $builder->emit_label($l_no_split);
        my $l_advance = $builder->new_label();
        $builder->emit_cond_br( $is_eof, $l_end, $l_advance );
        $builder->emit_label($l_advance);
        $builder->emit( 'local_store', 'void', [ $cursor_s, $builder->emit( 'add', 'i64', [ $cur, 1 ] ) ] );
        $builder->emit_jump($l_loop);
        $builder->emit_label($l_end);
        $builder->emit( 'shadow_pop', 'void', [] );        # pop argv
        $builder->emit( 'leave_func', 'void', [] );
    }

    method inject_runtime_init_argv_unix() {
        $driver->reset_locals();
        $builder->emit_label('M_init_argv');
        $builder->emit( 'enter_func', 'void', [] );
        my $argv_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $argv_s, $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('argv_array') ] ) ] );
        $builder->emit( 'shadow_push', 'void', [ $builder->emit( 'local_load', 'ptr', [$argv_s] ) ] );
        my $stack_ptr = $builder->emit( 'intrinsic_get_saved_stack_ptr', 'ptr', [$stack_ptr_offset] );
        my $argc      = $builder->emit( 'load_mem_disp',                 'i64', [ $stack_ptr, 0 ] );
        my $i_s       = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $i_s, 1 ] );    # Start at 1 to skip argv[0]
        my $l_loop = $builder->new_label();
        my $l_done = $builder->new_label();
        $builder->emit_label($l_loop);
        my $i = $builder->emit( 'local_load', 'i64', [$i_s] );
        $builder->emit_cond_br( $builder->emit( 'cmp_ge', 'Int', [ $i, $argc ] ), $l_done, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );

        # Get argv[i] from stack_ptr + 8 + i * 8
        my $argv_element_offset = $builder->emit( 'add',           'i64', [ $builder->emit( 'mul', 'i64', [ $i, 8 ] ), 8 ] );
        my $arg_ptr_addr        = $builder->emit( 'add',           'ptr', [ $stack_ptr,    $argv_element_offset ] );
        my $arg_c_str           = $builder->emit( 'load_mem_disp', 'ptr', [ $arg_ptr_addr, 0 ] );

        # strlen loop
        my $len_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $len_s, 0 ] );
        my $l_len_loop = $builder->new_label();
        my $l_len_done = $builder->new_label();
        $builder->emit_label($l_len_loop);
        my $curr_len = $builder->emit( 'local_load',    'i64', [$len_s] );
        my $char     = $builder->emit( 'load_mem_byte', 'Int', [ $arg_c_str, $curr_len ] );
        $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $char, 0 ] ), $l_len_done, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        $builder->emit( 'local_store', 'void', [ $len_s, $builder->emit( 'add', 'i64', [ $curr_len, 1 ] ) ] );
        $builder->emit_jump($l_len_loop);
        $builder->emit_label($l_len_done);
        my $len     = $builder->emit( 'local_load', 'i64', [$len_s] );
        my $arg_str = $builder->emit( 'call_func',  'ptr', [ 'M_str_slice', $arg_c_str, 0, $len ] );
        $builder->emit( 'shadow_push', 'void', [$arg_str] );

        # Re-allocate and copy
        my $argv    = $builder->emit( 'local_load', 'ptr', [$argv_s] );
        my $arr_ct  = $builder->emit( 'shr',        'i64', [ $builder->emit( 'load_mem_disp', 'i64', [ $argv, 0 ] ), 2 ] );
        my $new_sz  = $builder->emit( 'add', 'i64', [ $builder->emit( 'mul', 'i64', [ $builder->emit( 'add', 'i64', [ $arr_ct, 1 ] ), 8 ] ), 8 ] );
        my $new_arr = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', $new_sz ] );
        $builder->emit(
            'store_mem_disp',
            'void',
            [   $new_arr, 0,
                $builder->emit( 'or', 'i64', [ $builder->emit( 'shl', 'i64', [ $builder->emit( 'add', 'i64', [ $arr_ct, 1 ] ), 2 ] ), 1 ] )
            ]
        );

        # Copy old elements
        my $cp_i_s = $driver->alloc_local_slot();
        $builder->emit( 'local_store', 'void', [ $cp_i_s, 0 ] );
        my $l_cp_loop = $builder->new_label();
        my $l_cp_end  = $builder->new_label();
        $builder->emit_label($l_cp_loop);
        my $cp_i = $builder->emit( 'local_load', 'i64', [$cp_i_s] );
        $builder->emit_cond_br( $builder->emit( 'cmp_ge', 'Int', [ $cp_i, $arr_ct ] ), $l_cp_end, $builder->new_label() );
        $builder->emit_label( $builder->last_instruction->{false_l} );
        my $src_addr = $builder->emit( 'add', 'ptr', [ $builder->emit( 'add', 'ptr', [ $argv, 8 ] ), $builder->emit( 'mul', 'i64', [ $cp_i, 8 ] ) ] );
        my $el       = $builder->emit( 'load_mem_disp', 'Any', [ $src_addr, 0 ] );
        my $dst_addr
            = $builder->emit( 'add', 'ptr', [ $builder->emit( 'add', 'ptr', [ $new_arr, 8 ] ), $builder->emit( 'mul', 'i64', [ $cp_i, 8 ] ) ] );
        $builder->emit( 'store_mem_disp', 'void', [ $dst_addr, 0, $el ] );
        $builder->emit( 'local_store', 'void', [ $cp_i_s, $builder->emit( 'add', 'i64', [ $cp_i, 1 ] ) ] );
        $builder->emit_jump($l_cp_loop);
        $builder->emit_label($l_cp_end);
        my $append_addr
            = $builder->emit( 'add', 'ptr', [ $builder->emit( 'add', 'ptr', [ $new_arr, 8 ] ), $builder->emit( 'mul', 'i64', [ $arr_ct, 8 ] ) ] );
        $builder->emit( 'store_mem_disp', 'void', [ $append_addr, 0, $arg_str ] );
        $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('argv_array'), $new_arr ] );
        $builder->emit( 'local_store',    'void', [ $argv_s, $new_arr ] );
        $builder->emit( 'shadow_pop',     'void', [] );                                                    # pop arg_str
        $builder->emit( 'local_store',    'void', [ $i_s, $builder->emit( 'add', 'i64', [ $i, 1 ] ) ] );
        $builder->emit_jump($l_loop);
        $builder->emit_label($l_done);
        $builder->emit( 'shadow_pop', 'void', [] );                                                        # pop argv
        $builder->emit( 'leave_func', 'void', [] );
    }
}
1;
