package Brocken::Compiler::Lowering {
    use v5.40;
    use utf8;
    use feature 'class';
    no warnings 'portable', 'experimental::class';
    use Brocken::IR;
    use Brocken::AST;
    use Brocken::Type;

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
        field %native_funcs;
        field %our_vars;
        field $global_method_count = 0;
        field $our_var_next_offset = 256;
        field $class_id_counter    = 0;
        field $anon_counter        = 0;
        field @fragments;
        field @defer_stack;
        field @loop_stack;    # Stack of { next_l, last_l, redo_l }
        field $defer_active_depth = 0;
        field $_skip_runtime      = 0;
        field @exported_funcs;
        field $line_table_ptr_offset  = undef;
        field $line_table_size_offset = undef;

        # --- First-class undef pointer ---
        field $undef_ptr_offset = undef;
        field $stack_ptr_offset = undef;
        method class_info ()          { return %class_info }
        method exported_funcs ()      { return \@exported_funcs; }
        method skip_runtime           {$_skip_runtime}
        method set_skip_runtime($val) { $_skip_runtime = $val }
        ADJUST {
            $self->_initialize_root_scope();
        }

        method _initialize_root_scope() {

            # Standard I/O Handles (mapped to FileHandle type, NO sigils!)
            $current_scope->define( 'STDOUT', 'FileHandle', 0, undef, undef, undef, 176 );
            $current_scope->define( 'STDERR', 'FileHandle', 0, undef, undef, undef, 184 );
            $current_scope->define( 'STDIN',  'FileHandle', 0, undef, undef, undef, 192 );

            # Environment Hash (Both forms mapped to env_hash offset 200)
            $current_scope->define( '%ENV', 'Hash', 0, undef, undef, undef, 200 );
            $current_scope->define( '$ENV', 'Hash', 0, undef, undef, undef, 200 );

            # Argv Array (Both forms mapped to argv_array offset 208)
            $current_scope->define( '@ARGV', 'Array', 0, undef, undef, undef, 208 );
            $current_scope->define( '$ARGV', 'Array', 0, undef, undef, undef, 208 );

            # Default / Topic Variable $_
            $current_scope->define( '$_', 'Any', 0, undef, undef, undef, 216 );

            # Special variables
            $current_scope->define( '$^X', 'String', 0, undef, undef, undef, 224 );
            $current_scope->define( '$$',  'Int',    0, undef, undef, undef, 232 );
            $current_scope->define( '$0',  'String', 0, undef, undef, undef, 240 );
            $current_scope->define( '$^T', 'Int',    0, undef, undef, undef, 248 );
        }

        # --- Exact Write Barrier ---
        method _emit_write_barrier( $base, $offset, $val ) {
            my $l_next         = $builder->new_label();
            my $old            = $builder->emit( 'load_mem_disp', 'ptr', [ $base, $offset ] );
            my $l_old_not_null = $builder->new_label();
            $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $old, 0 ] ), $l_next, $l_old_not_null );
            $builder->emit_label($l_old_not_null);
            my $is_smi_old    = $builder->emit( 'and', 'i64', [ $old, 1 ] );
            my $l_old_not_smi = $builder->new_label();
            $builder->emit_cond_br( $builder->emit( 'cmp_ne', 'Int', [ $is_smi_old, 0 ] ), $l_next, $l_old_not_smi );
            $builder->emit_label($l_old_not_smi);
            {
                my $hdr      = $builder->emit( 'load_mem_disp', 'i64', [ $old, -8 ] );
                my $shared   = $builder->emit( 'and', 'i64', [ $builder->emit( 'shr', 'i64', [ $hdr, 62 ] ), 1 ] );
                my $l_local  = $builder->new_label();
                my $l_done   = $builder->new_label();
                my $l_atomic = $builder->new_label();
                $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $shared, 0 ] ), $l_local, $l_atomic );
                $builder->emit_label($l_atomic);
                $builder->emit( 'atomic_dec_ref', 'void', [$old] );
                $builder->emit_jump($l_done);
                $builder->emit_label($l_local);
                $builder->emit( 'local_dec_ref', 'void', [$old] );
                $builder->emit_label($l_done);
            }
            $builder->emit_label($l_next);

            # Store NEW
            $builder->emit( 'store_mem_disp', 'void', [ $base, $offset, $val ] );

            # IncRef NEW
            my $l_end          = $builder->new_label();
            my $l_new_not_null = $builder->new_label();
            $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $val, 0 ] ), $l_end, $l_new_not_null );
            $builder->emit_label($l_new_not_null);
            my $is_smi_new    = $builder->emit( 'and', 'i64', [ $val, 1 ] );
            my $l_new_not_smi = $builder->new_label();
            $builder->emit_cond_br( $builder->emit( 'cmp_ne', 'Int', [ $is_smi_new, 0 ] ), $l_end, $l_new_not_smi );
            $builder->emit_label($l_new_not_smi);
            {
                my $hdr      = $builder->emit( 'load_mem_disp', 'i64', [ $val, -8 ] );
                my $shared   = $builder->emit( 'and', 'i64', [ $builder->emit( 'shr', 'i64', [ $hdr, 62 ] ), 1 ] );
                my $l_local  = $builder->new_label();
                my $l_done   = $builder->new_label();
                my $l_atomic = $builder->new_label();
                $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $shared, 0 ] ), $l_local, $l_atomic );
                $builder->emit_label($l_atomic);
                $builder->emit( 'atomic_inc_ref', 'void', [$val] );
                $builder->emit_jump($l_done);
                $builder->emit_label($l_local);
                $builder->emit( 'local_inc_ref', 'void', [$val] );
                $builder->emit_label($l_done);
            }
            $builder->emit_label($l_end);
        }

        method _emit_bool_test($reg) {
            my $undef_ptr = $builder->emit( 'load_data_addr', 'ptr', [$undef_ptr_offset] );
            my $not_null  = $builder->emit( 'cmp_ne',         'Int', [ $reg,      0 ] );
            my $not_undef = $builder->emit( 'cmp_ne',         'Int', [ $reg,      $undef_ptr ] );
            my $not_zero  = $builder->emit( 'cmp_ne',         'Int', [ $reg,      1 ] );
            my $and1      = $builder->emit( 'and',            'i64', [ $not_null, $not_undef ] );
            return $builder->emit( 'and', 'i64', [ $and1, $not_zero ] );
        }

        method _emit_all_defers() {
            my @current = reverse @defer_stack;
            for my $fragment (@current) {
                $builder->push_instruction($_) for @$fragment;
            }
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

        method capture_fragment( $label, $logic_sub ) {
            my @saved = $builder->instructions;
            $builder->set_instructions();
            $logic_sub->();
            my @captured = $builder->instructions;
            push @fragments, \@captured;
            $builder->set_instructions(@saved);
        }

        method _lower_logical($node) {
            my $op       = $node->op;
            my $res_slot = $driver->alloc_local_slot();
            my $l_end    = $builder->new_label();
            my ( $l_reg, $l_typ ) = $self->lower( $node->left );
            $builder->emit( 'local_store', 'void', [ $res_slot, $l_reg ] );
            my $cond_reg;
            if ( $op eq '//' ) {
                my $undef_ptr = $builder->emit( 'load_data_addr', 'ptr', [$undef_ptr_offset] );
                my $not_null  = $builder->emit( 'cmp_ne',         'Int', [ $l_reg, 0 ] );
                my $not_undef = $builder->emit( 'cmp_ne',         'Int', [ $l_reg, $undef_ptr ] );
                $cond_reg = $builder->emit( 'and', 'i64', [ $not_null, $not_undef ] );
            }
            else {
                $cond_reg = $self->_emit_bool_test($l_reg);
            }
            my $l_false = $builder->new_label();
            my $l_true  = $builder->new_label();
            if ( $op eq '&&' ) {
                $builder->emit_cond_br( $cond_reg, $l_true, $l_end );
                $builder->emit_label($l_true);
            }
            else {
                $builder->emit_cond_br( $cond_reg, $l_end, $l_false );
                $builder->emit_label($l_false);
            }
            my ( $r_reg, $r_typ ) = $self->lower( $node->right );
            $builder->emit( 'local_store', 'void', [ $res_slot, $r_reg ] );
            $builder->emit_label($l_end);
            return ( $builder->emit( 'local_load', 'Any', [$res_slot] ), 'Any' );
        }

        method _generate_export_thunk( $node, $internal_name = undef, $export_name = undef ) {
            $internal_name //= 'M_' . $node->name;
            $export_name   //= 'E_' . $node->name;
            $builder->emit_label($export_name);
            $builder->emit( 'enter_func', 'void', [] );

            # --- 1. CAPTURE RAW REGS IMMEDIATELY ---
            my @saved_slots;
            my $arg_idx = 0;
            for my $p ( @{ $node->params } ) {
                my $param_type = $p->{type};
                my $ir_type    = ( $param_type eq 'Float' || $param_type eq 'double' ) ? 'double' : 'i64';
                my $slot       = $driver->alloc_local_slot();
                my $raw_reg    = $builder->emit( 'get_arg', $ir_type, [ $arg_idx++ ] );
                $builder->emit( 'local_store', 'void', [ $slot, $raw_reg ] );
                push @saved_slots, { slot => $slot, type => $param_type, ir_type => $ir_type };
            }

            # --- 2. INITIALIZE RUNTIME ---
            $builder->emit( 'call_func', 'void', ['M_runtime_init'] );
            my $giso_addr = $builder->emit( 'load_data_addr', 'ptr', [ $driver->global_iso_offset ] );
            my $iso_ptr   = $builder->emit( 'load_mem_disp',  'i64', [ $giso_addr, 0 ] );
            $builder->emit( 'set_isolate_ctx', 'void', [$iso_ptr] );

            # --- 3. BOX SAVED ARGUMENTS ---
            my @boxed_args;
            for my $s (@saved_slots) {
                my $raw = $builder->emit( 'local_load', $s->{ir_type}, [ $s->{slot} ] );
                if ( $s->{type} eq 'Int' || $s->{type} =~ /^Int\d+$/ ) {
                    my $shifted = $builder->emit( 'shl', 'i64', [ $raw, 1 ] );
                    push @boxed_args, $builder->emit( 'or', 'i64', [ $shifted, 1 ] );
                }
                else {
                    push @boxed_args, $raw;
                }
            }

            # --- 4. CALL INTERNAL LOGIC ---
            my $has_float   = grep { $_->{type} eq 'Float' || $_->{type} eq 'double' } @{ $node->params };
            my $ret_ir_type = $has_float ? 'double' : 'i64';
            my $result      = $builder->emit( 'call_func', $ret_ir_type, [ $internal_name, @boxed_args ] );
            $builder->emit( 'leave_func', $ret_ir_type, [$result] );
        }

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
            $self->inject_runtime_print_any();
            $self->inject_runtime_dump();
            $self->inject_runtime_ddx();
            $self->inject_runtime_dd();
            $self->inject_runtime_new_fiber();
            $self->inject_runtime_concat();
            $self->inject_runtime_to_string();
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
            my $t_bp          = $builder->emit( 'local_load', 'ptr', [$trace_bp_s] );
            my $t_depth       = $builder->emit( 'local_load', 'i64', [$trace_depth_s] );
            my $l_trace_next  = $builder->new_label();
            my $is_trace_done = $builder->emit( 'or', 'i64',
                [ $builder->emit( 'cmp_eq', 'Int', [ $t_bp, 0 ] ), $builder->emit( 'cmp_ge', 'Int', [ $t_depth, 30 ] ) ] );
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
            $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $builder->emit( 'local_load', 'ptr', [$root_slot] ), 0 ] ),
                $l_next, $l_not_null );
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
            my $off = $builder->emit( 'sub', 'i64',
                [ $builder->emit( 'sub', 'i64', [ $builder->emit( 'local_load', 'ptr', [$root_slot] ), 8 ] ), $block ] );
            my $hdr_slot = $driver->alloc_local_slot();
            $builder->emit( 'local_store', 'i64',
                [ $hdr_slot, $builder->emit( 'load_mem_disp', 'i64', [ $builder->emit( 'local_load', 'ptr', [$root_slot] ), -8 ] ) ] );
            my $cyc     = $builder->emit( 'load_iso_disp', 'i64', [ $driver->iso_offset('gc_cycle') ] );
            my $obj_cyc = $builder->emit( 'and', 'i64',
                [ $builder->emit( 'shr', 'i64', [ $builder->emit( 'local_load', 'i64', [$hdr_slot] ), 40 ] ), 0xFF ] );
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
                $l_next, $l_not_leaf
            );
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
                [   $builder->emit( 'local_load', 'ptr', [$root_slot] ),
                    $builder->emit( 'add',        'i64', [ $builder->emit( 'mul', 'i64', [ $ai, 8 ] ), 8 ] )
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
            my $voff_ptr
                = $builder->emit( 'sub', 'ptr', [ $first, $builder->emit( 'add', 'i64', [ $builder->emit( 'mul', 'i64', [ $pi, 8 ] ), 16 ] ) ] );
            my $voff = $builder->emit( 'load_mem_disp', 'i64', [ $voff_ptr, 0 ] );
            my $ch   = $builder->emit( 'load_mem_disp', 'ptr',
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
                [ $driver->iso_offset('heap_limit'), $builder->emit( 'add', 'ptr', [ $cbh, $builder->emit( 'mul', 'i64', [ $final_idx, 128 ] ) ] ) ]
            );
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
            my $is_head
                = $builder->emit( 'cmp_eq', 'Int', [ $fib, $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('fiber_head') ] ) ] );
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
                [ $builder->emit( 'sub', 'ptr', [ $first, $builder->emit( 'add', 'i64', [ 16, $builder->emit( 'mul', 'i64', [ $i, 8 ] ) ] ) ] ), 0 ]
            );
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

            # FIX: Use DFFF mask to preserve both RC (48..60) and Leaf Flags (62..63)
            my $fhdr = $builder->emit( 'or', 'i64',
                [ $sz_raw, $builder->emit( 'and', 'i64', [ $psz, $builder->emit( 'constant', 'i64', [ hex("DFFF000000000000") ] ) ] ) ] );
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
                [ $sz, $builder->emit( 'and', 'i64', [ $psz, $builder->emit( 'constant', 'i64', [ hex("DFFF000000000000") ] ) ] ) ] );
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
            $builder->emit_cond_br( $builder->emit( 'and', 'i64', [ $builder->emit( 'shr', 'i64', [ $hdr, 61 ] ), 1 ] ),
                $l_is_forwarded, $l_do_promote );
            $builder->emit_label($l_is_forwarded);
            $builder->emit( 'leave_func', 'ptr',
                [ $builder->emit( 'and', 'i64', [ $hdr, $builder->emit( 'constant', 'i64', [ hex("FFFFFFFFFFFF") ] ) ] ) ] );
            $builder->emit_label($l_do_promote);
            my $sz         = $builder->emit( 'and', 'i64', [ $hdr, $builder->emit( 'constant', 'i64', [ hex("FFFFFFFFFF") ] ) ] );
            my $payload_sz = $builder->emit( 'sub', 'i64', [ $sz,  8 ] );

            # Carry RC values (and Leaf tags) from Nursery to Tenured space perfectly
            my $psz_with_flags = $builder->emit( 'or', 'i64',
                [ $payload_sz, $builder->emit( 'and', 'i64', [ $hdr, $builder->emit( 'constant', 'i64', [ hex("DFFF000000000000") ] ) ] ) ] );
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
            $builder->emit_cond_br( $builder->emit( 'and', 'i64', [ $builder->emit( 'shr', 'i64', [ $hdr, 61 ] ), 1 ] ),
                $l_is_forwarded, $l_do_evacuate );
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
            $builder->emit(
                'local_store',
                'void',
                [   $sweep_s, $builder->emit( 'add', 'ptr', [ $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('heap_base') ] ), 1032 ] )
                ]
            );

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
            $builder->emit( 'intrinsic_print', 'void', [$v] );
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
            $builder->emit( 'store_mem_disp', 'void',
                [ $is, $driver->iso_offset('fiber_head'), $builder->emit( 'local_load', 'ptr', [$fcb_slot] ) ] );
            $builder->emit( 'shadow_pop', 'void', [] );
            $builder->emit( 'leave_func', 'void', [ $builder->emit( 'local_load', 'ptr', [$fcb_slot] ) ] );
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
                        'load_mem_byte', 'i64',
                        [ $builder->emit( 'local_load', 'ptr', [$s1_slot] ), $builder->emit( 'add', 'i64', [ $ci, 16 ] ) ]
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
                    $builder->emit(
                        'add', 'i64', [ $builder->emit( 'add', 'i64', [ $cj, 16 ] ), $builder->emit( 'local_load', 'i64', [$l1_slot] ) ]
                    ),
                    $builder->emit(
                        'load_mem_byte', 'i64',
                        [ $builder->emit( 'local_load', 'ptr', [$s2_slot] ), $builder->emit( 'add', 'i64', [ $cj, 16 ] ) ]
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
            my $l_is_str  = $builder->new_label();
            my $l_not_str = $builder->new_label();
            $builder->emit_cond_br( $is_leaf, $l_is_str, $l_not_str );

            # 1. String: already a string, return directly
            $builder->emit_label($l_is_str);
            $builder->emit( 'leave_func', 'void', [$ptr_val] );

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

        method _emit_runtime_init_sub() {
            $builder->emit_label('M_runtime_init');
            $builder->emit( 'enter_func', 'void', [] );
            my $giso_ptr     = $builder->emit( 'load_data_addr', 'ptr', [ $driver->global_iso_offset ] );
            my $l_done       = $builder->new_label();
            my $l_init       = $builder->new_label();
            my $existing_iso = $builder->emit( 'load_mem_disp', 'i64', [ $giso_ptr, 0 ] );
            $builder->emit_cond_br( $builder->emit( 'cmp_ne', 'Int', [ $existing_iso, 0 ] ), $l_done, $l_init );
            $builder->emit_label($l_init);
            my $iso = $builder->emit( 'intrinsic_alloc', 'ptr', [1024] );
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
            $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('mark_stack_base'),  $ms ] );
            $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('mark_stack_ptr'),   $ms ] );
            $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('mark_stack_limit'), $builder->emit( 'add', 'ptr', [ $ms, 1048576 ] ) ] );

            # --- Generational Nursery Initialization (64KB) ---
            my $raw_nursery = $builder->emit( 'intrinsic_alloc', 'ptr', [65536] );
            $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('nursery_base'), $raw_nursery ] );
            $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('nursery_ptr'),  $raw_nursery ] );
            $builder->emit( 'store_iso_disp', 'void',
                [ $driver->iso_offset('nursery_limit'), $builder->emit( 'add', 'ptr', [ $raw_nursery, 65536 ] ) ] );

            # --- Tenured Heap Initialization (Two 2MB Semi-Spaces) ---
            my $raw_heap = $builder->emit( 'intrinsic_alloc', 'ptr', [4194304] );
            my $mask     = $builder->emit( 'constant',        'i64', [ hex("FFFFFFFFFFFF0000") ] );
            my $hp       = $builder->emit( 'and',             'i64', [ $builder->emit( 'add', 'ptr', [ $raw_heap, 65535 ] ), $mask ] );
            $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('heap_base'),  $hp ] );
            $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('heap_ptr'),   $builder->emit( 'add', 'ptr', [ $hp, 1024 ] ) ] );
            $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('heap_limit'), $builder->emit( 'add', 'ptr', [ $hp, 2097152 ] ) ] );

            # Setup ToSpace boundaries at offset 88 and 96
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
            {    # Globals

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
                my $buf
                    = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', $builder->emit( 'constant', 'i64', [ 512 | hex("C000000000000000") ] ) ] );
                my $len       = $builder->emit( 'intrinsic_get_module_filename', 'i64', [$buf] );
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
            my $payload_sz     = $builder->emit( 'add', 'i64', [ $len,        16 ] );
            my $psz_with_flags = $builder->emit( 'or',  'i64', [ $payload_sz, $builder->emit( 'constant', 'i64', [ hex("C000000000000000") ] ) ] );
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
            $builder->emit( 'local_store', 'void',
                [ $idx_s, $builder->emit( 'and', 'i64', [ $h, $builder->emit( 'local_load', 'i64', [$mask_s] ) ] ) ] );
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
            $builder->emit( 'local_store', 'void',
                [ $idx_s, $builder->emit( 'and', 'i64', [ $h, $builder->emit( 'local_load', 'i64', [$mask_s] ) ] ) ] );
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
            $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $old_v, $builder->emit( 'constant', 'i64', [2] ) ] ), $l_was_del,
                $l_upd_done );
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
            my $k_addr = $builder->emit( 'add', 'ptr',
                [ $builder->emit( 'add', 'ptr', [ $builder->emit( 'local_load', 'ptr', [$old_ent_s] ), 8 ] ), $offset ] );
            my $k = $builder->emit( 'load_mem_disp', 'ptr', [ $k_addr, 0 ] );
            $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $k, 0 ] ), $builder->new_label(), $builder->new_label() );
            my $l_skip = $builder->last_instruction->{true_l};
            $builder->emit_label( $builder->last_instruction->{false_l} );

            # Also skip if key is tombstone (2)
            $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $k, $builder->emit( 'constant', 'i64', [2] ) ] ),
                $l_skip, $builder->new_label() );
            $builder->emit_label( $builder->last_instruction->{false_l} );
            my $v = $builder->emit( 'load_mem_disp', 'Any', [ $k_addr, 8 ] );

            # Skip if value is tombstone (2) (was deleted)
            $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $v, $builder->emit( 'constant', 'i64', [2] ) ] ),
                $l_skip, $builder->new_label() );
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
            my $k_addr
                = $builder->emit( 'add', 'ptr', [ $builder->emit( 'add', 'ptr', [ $entries, 8 ] ), $builder->emit( 'mul', 'i64', [ $i, 16 ] ) ] );
            my $k = $builder->emit( 'load_mem_disp', 'ptr', [ $k_addr, 0 ] );
            $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $k, 0 ] ), $builder->new_label(), $builder->new_label() );
            my $l_skip = $builder->last_instruction->{true_l};
            $builder->emit_label( $builder->last_instruction->{false_l} );

            # Check for key tombstone
            $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $k, $builder->emit( 'constant', 'i64', [2] ) ] ),
                $l_skip, $builder->new_label() );
            $builder->emit_label( $builder->last_instruction->{false_l} );

            # Check for value tombstone
            my $v = $builder->emit( 'load_mem_disp', 'Any', [ $k_addr, 8 ] );
            $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $v, $builder->emit( 'constant', 'i64', [2] ) ] ),
                $l_skip, $builder->new_label() );
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
            my $k_addr
                = $builder->emit( 'add', 'ptr', [ $builder->emit( 'add', 'ptr', [ $entries, 8 ] ), $builder->emit( 'mul', 'i64', [ $i, 16 ] ) ] );
            my $k = $builder->emit( 'load_mem_disp', 'ptr', [ $k_addr, 0 ] );
            $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $k, 0 ] ), $builder->new_label(), $builder->new_label() );
            my $l_skip = $builder->last_instruction->{true_l};
            $builder->emit_label( $builder->last_instruction->{false_l} );
            $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $k, $builder->emit( 'constant', 'i64', [2] ) ] ),
                $l_skip, $builder->new_label() );
            $builder->emit_label( $builder->last_instruction->{false_l} );
            my $v = $builder->emit( 'load_mem_disp', 'Any', [ $k_addr, 8 ] );
            $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $v, $builder->emit( 'constant', 'i64', [2] ) ] ),
                $l_skip, $builder->new_label() );
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
            my $argv   = $builder->emit( 'local_load', 'ptr', [$argv_s] );
            my $arr_ct = $builder->emit( 'shr',        'i64', [ $builder->emit( 'load_mem_disp', 'i64', [ $argv, 0 ] ), 2 ] );
            my $new_sz = $builder->emit( 'add', 'i64', [ $builder->emit( 'mul', 'i64', [ $builder->emit( 'add', 'i64', [ $arr_ct, 1 ] ), 8 ] ), 8 ] );
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
            my $src_addr
                = $builder->emit( 'add', 'ptr', [ $builder->emit( 'add', 'ptr', [ $argv, 8 ] ), $builder->emit( 'mul', 'i64', [ $cp_i, 8 ] ) ] );
            my $el = $builder->emit( 'load_mem_disp', 'Any', [ $src_addr, 0 ] );
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
            my $argv   = $builder->emit( 'local_load', 'ptr', [$argv_s] );
            my $arr_ct = $builder->emit( 'shr',        'i64', [ $builder->emit( 'load_mem_disp', 'i64', [ $argv, 0 ] ), 2 ] );
            my $new_sz = $builder->emit( 'add', 'i64', [ $builder->emit( 'mul', 'i64', [ $builder->emit( 'add', 'i64', [ $arr_ct, 1 ] ), 8 ] ), 8 ] );
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
            my $src_addr
                = $builder->emit( 'add', 'ptr', [ $builder->emit( 'add', 'ptr', [ $argv, 8 ] ), $builder->emit( 'mul', 'i64', [ $cp_i, 8 ] ) ] );
            my $el = $builder->emit( 'load_mem_disp', 'Any', [ $src_addr, 0 ] );
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

        # --- AST Lowering Dispatcher ---
        method lower($node) {
            return ( undef, 'void' ) unless defined $node;
            my $nt = ref($node);
            $nt =~ s/.*:://;

            # Emit source location trace if line number is present
            if ( $node->line > 0 ) {
                $builder->emit( 'source_loc', 'void', [ $node->line, $node->col, $node->file ] );
            }
            my $m = "lower_$nt";
            return $self->$m($node) if $self->can($m);
            die "Lowering Error: No handler for node type $nt";
        }

        method lower_program($nodes) {
            $driver->set_data_segment($data_segment);
            $driver->set_global_iso_offset( $data_segment->add_raw_bytes( "\0" x 8 ) );
            $driver->set_exception_table_offset( $data_segment->add_raw_bytes( "\0" x 8 ) );

            # --- Initialize undef singleton ---
            $undef_ptr_offset = $data_segment->add_raw_bytes( pack( 'Q<', 0 ) );

            # --- Initialize stack_ptr_offset ---
            $stack_ptr_offset = $data_segment->add_raw_bytes( pack( 'Q<', 0 ) );

            # --- Initialize line-table offsets ---
            $line_table_ptr_offset  = $data_segment->add_raw_bytes( pack( 'Q<', 0 ) );
            $line_table_size_offset = $data_segment->add_raw_bytes( pack( 'Q<', 0 ) );
            $driver->set_line_table_ptr_offset($line_table_ptr_offset);
            $driver->set_line_table_size_offset($line_table_size_offset);
            $builder->emit_jump('L_MAIN_START');
            $self->inject_runtime();
            $self->_emit_runtime_init_sub();
            $self->register_classes($nodes);

            for my $n (@$nodes) {
                if ( $n isa Brocken::AST::Stmt::OurDecl ) {
                    my $name = $n->name;
                    if ( !exists $our_vars{$name} ) {
                        $our_vars{$name} = $our_var_next_offset;
                        $our_var_next_offset += 8;
                    }
                    $current_scope->define( $name, $n->type, 0, undef, undef, undef, $our_vars{$name} ) unless $current_scope->resolve($name);
                }
            }
            my @main_statements;
            for my $n (@$nodes) {
                if ( $n isa Brocken::AST::OOP::Method || $n isa Brocken::AST::OOP::ClassDecl || $n isa Brocken::AST::NativeDecl ) {
                    $self->lower($n);
                }
                else { push @main_statements, $n; }
            }
            $builder->emit_label('L_MAIN_START');

            # Save raw RSP on non-Windows platforms before pushing frame structures
            if ( $driver->os ne 'win64' ) {
                $builder->emit( 'intrinsic_save_stack_ptr', 'void', [$stack_ptr_offset] );
            }
            $builder->emit( 'enter_func', 'void', [] );
            $builder->emit( 'call_func',  'void', ["M_runtime_init"] );
            my $iso_slot = $builder->emit( 'load_data_addr', 'ptr', [ $driver->global_iso_offset ] );
            my $iso      = $builder->emit( 'load_mem_disp',  'i64', [ $iso_slot, 0 ] );
            $builder->emit( 'set_isolate_ctx', 'void', [$iso] );
            my $extab_off_ptr = $builder->emit( 'load_data_addr', 'ptr', [ $driver->exception_table_offset ] );
            my $extab_off     = $builder->emit( 'load_mem_disp',  'i64', [ $extab_off_ptr, 0 ] );
            my $data_base     = $builder->emit( 'load_data_addr', 'ptr', [0] );
            my $extab_ptr     = $builder->emit( 'add',            'ptr', [ $data_base, $extab_off ] );
            $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('exception_table'), $extab_ptr ] );
            my $fcb = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('current_fcb') ] );
            my $bp  = $builder->emit( 'get_bp',        'ptr', [] );
            $builder->emit( 'store_mem_disp', 'void', [ $fcb, $driver->fcb_offset('stack_base'), $bp ] );
            my $stm = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('state_ptr') ] );

            for my $cn ( sort keys %class_info ) {
                my $c           = $class_info{$cn};
                my $ptr_count   = scalar @{ $c->{ptr_offsets} };
                my $vt_size     = ( $ptr_count + 1 ) * 8 + ( $global_method_count * 8 );
                my $vt          = $builder->emit( 'intrinsic_alloc', 'ptr', [$vt_size] );
                my $method_base = $builder->emit( 'add',             'ptr', [ $vt, ( $ptr_count + 1 ) * 8 ] );
                $builder->emit( 'store_mem_disp', 'void', [ $method_base, -8, $builder->emit( 'constant', 'i64', [$ptr_count] ) ] );
                for ( my $i = 0; $i < $ptr_count; $i++ ) {
                    $builder->emit( 'store_mem_disp', 'void',
                        [ $method_base, -16 - ( $i * 8 ), $builder->emit( 'constant', 'i64', [ $c->{ptr_offsets}[$i] ] ) ] );
                }
                for my $mn ( @{ $c->{method_names} } ) {
                    my $owner = $cn;
                    my $curr  = $cn;
                    while ( defined $curr ) {
                        my $p_info = $class_info{$curr};
                        if ( exists $p_info->{own_methods}{$mn} || exists $p_info->{own_fields}{$mn} ) {
                            $owner = $curr;
                            last;
                        }
                        $curr = $p_info->{parent_class};
                    }
                    my $m_addr = $builder->emit( 'load_func_addr', 'ptr', ["M_${owner}::$mn"] );
                    $builder->emit( 'store_mem_disp', 'void', [ $method_base, $global_methods{$mn} * 8, $m_addr ] );
                }
                $builder->emit( 'store_mem_disp', 'void', [ $stm, $c->{id} * 8, $method_base ] );
            }
            $current_func_name = 'L_MAIN_START';
            @func_locals       = ();
            $self->lower_block( \@main_statements );
            $self->_emit_all_defers();
            if   ( $self->skip_runtime ) { $builder->emit( 'leave_func',     'i64',  [ $builder->emit( 'constant', 'i64', [1] ) ] ); }
            else                         { $builder->emit( 'intrinsic_exit', 'void', [ $builder->emit( 'constant', 'i64', [0] ) ] ); }
            while (@fragments) { my $f = shift @fragments; $builder->push_instruction($_) for @$f; }
            $builder->emit( 'intrinsic_emit_runtime', 'void', [] ) unless $self->skip_runtime;
        }

        method lower_Const($node) {
            if ( $node->type eq 'String' ) {
                return ( $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string( $node->value ) ] ), 'String' );
            }
            if ( $node->type eq 'Class' ) { return ( $builder->emit( 'constant',       'i64', [0] ),                 $node->value ) }
            if ( $node->type eq 'Undef' ) { return ( $builder->emit( 'load_data_addr', 'ptr', [$undef_ptr_offset] ), 'Undef' ); }
            if ( $node->type eq 'i64' || $node->type eq 'ptr' ) {
                return ( $builder->emit( 'constant', $node->type, [ $node->value ] ), $node->type );
            }
            if ( $node->type eq 'Float' || $node->type eq 'double' ) {
                return ( $builder->emit( 'constant', 'double', [ unpack( 'Q<', pack( 'd<', $node->value ) ) ] ), 'Float' );
            }
            return ( $builder->emit( 'constant', 'i64', [ ( $node->value << 1 ) | 1 ] ), 'Int' );
        }

        method lower_Var($node) {
            my $s = $current_scope->resolve( $node->name ) // die "Undeclared variable: " . $node->name;

            # Global isolate intercept
            if ( defined $s->isolate_offset ) {
                return ( $builder->emit( 'load_iso_disp', $s->type, [ $s->isolate_offset ] ), $s->type );
            }
            if ( defined $s->stack_offset && $s->stack_offset < 0 ) {
                my $sl_ptr = $builder->emit( 'local_load', 'ptr', [ $current_scope->resolve('$self')->stack_offset ] );
                return ( $builder->emit( 'load_mem_disp', 'Any', [ $sl_ptr, abs( $s->stack_offset ) ] ), 'Any' );
            }
            if ( $s->is_state ) {
                return (
                    $builder->emit(
                        'load_mem_disp', $s->type,
                        [ $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('state_ptr') ] ), 4096 + ( $s->state_idx * 8 ) ]
                    ),
                    $s->type
                );
            }

            # FIX: If the variable is tracked in the Shadow Stack, ALWAYS load it from there!
            # If the GC evacuates the object, the shadow stack is updated, guaranteeing safety.
            if ( defined $s->shadow_offset ) {
                return ( $builder->emit( 'load_mem_disp', $s->type, [ $s->shadow_offset, 0 ] ), $s->type );
            }
            return ( $builder->emit( 'local_load', $s->type, [ $s->stack_offset ] ), $s->type );
        }

        method lower_VarDecl($node) {
            my ( $vr, $vt ) = $self->lower( $node->value );
            my $sl  = $driver->alloc_local_slot();
            my $ft  = $node->type eq 'Any' ? $vt : $node->type;
            my $sho = undef;
            if ( $ft =~ /^(Any|String|Array|Fiber|Class|Undef)$/ || $ft !~ /^(Int|Float|i64|double|ptr|void)$/ ) {
                $sho = $builder->emit( 'shadow_get', 'ptr', [] );
                $builder->emit( 'shadow_push', 'void', [$vr] );
            }
            $current_scope->define( $node->name, $ft, 0, undef, $sl, $sho );
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

        method lower_OurDecl($node) {
            my $name = $node->name;
            if ( !exists $our_vars{$name} ) {
                $our_vars{$name} = $our_var_next_offset;
                $our_var_next_offset += 8;
                die "Too many global variables" if $our_var_next_offset > 1024;
            }
            my $off  = $our_vars{$name};
            my $type = $node->type;
            if ( defined $node->value ) {
                my ( $vr, $vt ) = $self->lower( $node->value );
                $builder->emit( 'store_iso_disp', 'void', [ $off, $vr ] );
                $type = $node->type eq 'Any' ? $vt : $node->type;
            }
            if ( !$current_scope->has_local_symbol($name) ) {
                $current_scope->define( $name, $type, 0, undef, undef, undef, $off );
            }
            return ( undef, 'void' );
        }

        method lower_Assignment($node) {
            my ( $vr, $vt ) = $self->lower( $node->value );
            if ( $node->name isa Brocken::AST::Expr::IndexExpr ) {
                my $idx_expr = $node->name;
                my ( $src_reg, $src_type ) = $self->lower( $idx_expr->source );
                my $l_not_null = $builder->new_label();
                $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $src_reg, 0 ] ), $builder->new_label(), $l_not_null );
                $builder->emit_label( $builder->last_instruction->{true_l} );
                $builder->emit( 'intrinsic_throw', 'void', [255] );
                $builder->emit_label($l_not_null);
                $builder->emit( 'shadow_push', 'void', [$src_reg] );
                $builder->emit( 'shadow_push', 'void', [$vr] );
                my ( $idx_reg, $idx_type ) = $self->lower( $idx_expr->index );
                my $l_is_hash = $builder->new_label();
                my $l_is_arr  = $builder->new_label();
                my $l_end     = $builder->new_label();
                my $tag_word  = $builder->emit( 'load_mem_disp', 'i64', [ $src_reg,  0 ] );
                my $type_tag  = $builder->emit( 'and',           'i64', [ $tag_word, 3 ] );
                $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $type_tag, 3 ] ), $l_is_hash, $l_is_arr );
                $builder->emit_label($l_is_arr);
                my $raw_idx = $builder->emit( 'shr', 'i64', [ $idx_reg, 1 ] );
                my $addr    = $builder->emit( 'add', 'ptr',
                    [ $builder->emit( 'add', 'ptr', [ $src_reg, 8 ] ), $builder->emit( 'mul', 'i64', [ $raw_idx, 8 ] ) ] );

                if ( $vt =~ /^(Any|String|Array|Hash|Tuple|Fiber|Class|Undef)$/ || $vt !~ /^(Int|Float|i64|double|ptr|void)$/ ) {
                    $self->_emit_write_barrier( $addr, 0, $vr );
                }
                else { $builder->emit( 'store_mem_disp', 'void', [ $addr, 0, $vr ] ); }
                $builder->emit_jump($l_end);
                $builder->emit_label($l_is_hash);
                my $k_str = ( $idx_type eq 'String' ) ? $idx_reg : $builder->emit( 'call_func', 'ptr', [ 'M_any_to_str', $idx_reg ] );
                $builder->emit( 'call_func', 'void', [ 'M_hash_insert', $src_reg, $k_str, $vr ] );
                $builder->emit_label($l_end);
                $builder->emit( 'shadow_pop', 'void', [] );
                $builder->emit( 'shadow_pop', 'void', [] );
                return ( $vr, $vt );
            }
            if ( $node->name isa Brocken::AST::Expr::MethodCall ) {    # XXX: lvalue methods?
                my $mc        = $node->name;
                my $inv       = $mc->object;
                my $mn        = "set_" . $mc->method;
                my $sp_backup = $builder->emit( 'shadow_get', 'ptr', [] );
                my ( $or, $ot ) = $self->lower($inv);
                $builder->emit( 'shadow_push', 'void', [$or] );
                $builder->emit( 'shadow_push', 'void', [$vr] );
                my $vtp    = $builder->emit( 'load_mem_disp', 'ptr', [ $or, 0 ] );
                my $fn_idx = $global_methods{$mn} // die "Unknown setter method $mn";
                my $fn     = $builder->emit( 'load_mem_disp', 'ptr', [ $vtp, $fn_idx * 8 ] );
                $builder->emit( 'call_reg', 'i64', [ $fn, $or, $vr ] );
                $builder->emit( 'shadow_set', 'void', [$sp_backup] );
                return ( $vr, $vt );
            }
            my $s = $current_scope->resolve( $node->name ) // die "Undeclared variable: " . $node->name;

            # global isolate intercept
            if ( defined $s->isolate_offset ) {
                $builder->emit( 'store_iso_disp', 'void', [ $s->isolate_offset, $vr ] );
                return ( $vr, $s->type );
            }
            if ( defined $s->stack_offset && $s->stack_offset < 0 ) {
                my $sl_ptr = $builder->emit( 'local_load', 'ptr', [ $current_scope->resolve('$self')->stack_offset ] );
                if ( $vt =~ /^(Any|String|Array|Hash|Tuple|Fiber|Class|Undef)$/ || $vt !~ /^(Int|Float|i64|double|ptr|void)$/ ) {
                    $self->_emit_write_barrier( $sl_ptr, abs( $s->stack_offset ), $vr );
                }
                else { $builder->emit( 'store_mem_disp', 'void', [ $sl_ptr, abs( $s->stack_offset ), $vr ] ); }
            }
            elsif ( $s->is_state ) {
                $builder->emit( 'store_mem_disp', 'void',
                    [ $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('state_ptr') ] ), 4096 + ( $s->state_idx * 8 ), $vr ] );
            }
            else {
                $builder->emit( 'local_store', 'void', [ $s->stack_offset, $vr ] );
                if ( defined $s->shadow_offset ) { $builder->emit( 'store_mem_disp', 'void', [ $s->shadow_offset, 0, $vr ] ) }
            }
            return ( $vr, $s->type );
        }

        method lower_Exists($node) {
            if ( $node->expr isa Brocken::AST::Expr::IndexExpr ) {
                my ( $src_reg, $src_type ) = $self->lower( $node->expr->source );
                $builder->emit( 'shadow_push', 'void', [$src_reg] );
                my ( $idx_reg, $idx_type ) = $self->lower( $node->expr->index );
                my $k_str = ( $idx_type eq 'String' ) ? $idx_reg : $builder->emit( 'call_func', 'ptr', [ 'M_any_to_str', $idx_reg ] );
                my $res   = $builder->emit( 'call_func', 'i64', [ 'M_hash_exists', $src_reg, $k_str ] );
                $builder->emit( 'shadow_pop', 'void', [] );
                return ( $res, 'Int' );
            }
            die "Exists operator requires a hash index expression";
        }

        method lower_Delete($node) {
            if ( $node->expr isa Brocken::AST::Expr::IndexExpr ) {
                my ( $src_reg, $src_type ) = $self->lower( $node->expr->source );
                $builder->emit( 'shadow_push', 'void', [$src_reg] );
                my ( $idx_reg, $idx_type ) = $self->lower( $node->expr->index );
                my $k_str = ( $idx_type eq 'String' ) ? $idx_reg : $builder->emit( 'call_func', 'ptr', [ 'M_any_to_str', $idx_reg ] );
                my $res   = $builder->emit( 'call_func', 'Any', [ 'M_hash_delete', $src_reg, $k_str ] );
                $builder->emit( 'shadow_pop', 'void', [] );
                return ( $res, 'Any' );
            }
            die "Delete operator requires a hash index expression";
        }

        method lower_UnaryOp($node) {
            my ( $r, $t ) = $self->lower( $node->expr );
            if ( $node->op eq '!' ) {
                my $raw = $builder->emit( 'cmp_eq', 'Int', [ $r, 1 ] );
                return ( $builder->emit( 'add', 'i64', [ $builder->emit( 'mul', 'i64', [ $raw, 2 ] ), 1 ] ), 'Int' );
            }
            if ( $node->op eq '-' ) {
                my $neg = $builder->emit( 'sub', 'i64', [ 0, $builder->emit( 'div', 'i64', [ $builder->emit( 'sub', 'i64', [ $r, 1 ] ), 2 ] ) ] );
                return ( $builder->emit( 'add', 'i64', [ $builder->emit( 'mul', 'i64', [ $neg, 2 ] ), 1 ] ), 'Int' );
            }
            die "Unary " . $node->op;
        }

        method lower_BinOp($node) {
            if ( $node->op eq '&&' || $node->op eq '||' || $node->op eq '//' ) { return $self->_lower_logical($node); }
            if ( $node->op eq '..' || $node->op eq '...' ) {
                my ( $lr, $lt ) = $self->lower( $node->left );
                $builder->emit( 'shadow_push', 'void', [$lr] );
                my ( $rr, $rt ) = $self->lower( $node->right );
                $builder->emit( 'shadow_push', 'void', [$rr] );

                # Untag both operands: (val - 1) / 2
                my $l_val = $builder->emit( 'div', 'i64', [ $builder->emit( 'sub', 'i64', [ $lr, 1 ] ), 2 ] );
                my $r_val = $builder->emit( 'div', 'i64', [ $builder->emit( 'sub', 'i64', [ $rr, 1 ] ), 2 ] );

                # diff = r_val - l_val
                my $diff = $builder->emit( 'sub', 'i64', [ $r_val, $l_val ] );

                # count = diff + 1
                my $count      = $builder->emit( 'add',    'i64', [ $diff,  1 ] );
                my $is_empty   = $builder->emit( 'cmp_lt', 'Int', [ $r_val, $l_val ] );
                my $count_slot = $driver->alloc_local_slot();
                my $l_nonempty = $builder->new_label();
                my $l_end      = $builder->new_label();
                $builder->emit_cond_br( $is_empty, $l_end, $l_nonempty );

                # If empty, store 0
                $builder->emit( 'local_store', 'void', [ $count_slot, $builder->emit( 'constant', 'i64', [0] ) ] );
                $builder->emit_jump($l_end);

                # If non-empty, store count
                $builder->emit_label($l_nonempty);
                $builder->emit( 'local_store', 'void', [ $count_slot, $count ] );
                $builder->emit_label($l_end);
                my $final_count = $builder->emit( 'local_load', 'i64', [$count_slot] );

                # Allocate Array: size = 8 + final_count * 8
                my $size = $builder->emit( 'add',       'i64', [ 8,            $builder->emit( 'mul', 'i64', [ $final_count, 8 ] ) ] );
                my $arr  = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', $size ] );

                # Tag Array: (final_count << 2) | 1
                my $tag = $builder->emit( 'or', 'i64', [ $builder->emit( 'shl', 'i64', [ $final_count, 2 ] ), 1 ] );
                $builder->emit( 'store_mem_disp', 'void', [ $arr, 0, $tag ] );

                # Loop and fill
                my $idx_s = $driver->alloc_local_slot();
                $builder->emit( 'local_store', 'void', [ $idx_s, $builder->emit( 'constant', 'i64', [0] ) ] );
                my $l_loop_cond = $builder->new_label();
                my $l_loop_body = $builder->new_label();
                my $l_loop_end  = $builder->new_label();
                $builder->emit_jump($l_loop_cond);
                $builder->emit_label($l_loop_body);
                my $idx = $builder->emit( 'local_load', 'i64', [$idx_s] );

                # tagged_val = ((l_val + idx) << 1) | 1
                my $raw_val    = $builder->emit( 'add', 'i64', [ $l_val, $idx ] );
                my $tagged_val = $builder->emit( 'or',  'i64', [ $builder->emit( 'shl', 'i64', [ $raw_val, 1 ] ), 1 ] );

                # offset = 8 + idx * 8
                my $off = $builder->emit( 'add', 'i64', [ 8, $builder->emit( 'mul', 'i64', [ $idx, 8 ] ) ] );
                my $ptr = $builder->emit( 'add', 'ptr', [ $arr, $off ] );
                $builder->emit( 'store_mem_disp', 'void', [ $ptr, 0, $tagged_val ] );
                my $next_idx = $builder->emit( 'add', 'i64', [ $idx, 1 ] );
                $builder->emit( 'local_store', 'void', [ $idx_s, $next_idx ] );
                $builder->emit_label($l_loop_cond);
                my $chk_idx = $builder->emit( 'local_load', 'i64', [$idx_s] );
                $builder->emit_cond_br( $builder->emit( 'cmp_lt', 'Int', [ $chk_idx, $final_count ] ), $l_loop_body, $l_loop_end );
                $builder->emit_label($l_loop_end);
                $builder->emit( 'shadow_pop', 'void', [] );
                $builder->emit( 'shadow_pop', 'void', [] );
                return ( $arr, 'Array' );
            }
            if ( $node->op eq '.' ) {
                my ( $lr, $lt ) = $self->lower( $node->left );
                $builder->emit( 'shadow_push', 'void', [$lr] );
                my ( $rr, $rt ) = $self->lower( $node->right );
                $builder->emit( 'shadow_push', 'void', [$rr] );
                my $lc  = $lt eq 'String' ? $lr : $builder->emit( 'call_func', 'ptr', [ 'M_any_to_str', $lr ] );
                my $rc  = $rt eq 'String' ? $rr : $builder->emit( 'call_func', 'ptr', [ 'M_any_to_str', $rr ] );
                my $res = $builder->emit( 'call_func', 'ptr', [ 'M_concat', $lc, $rc ] );
                $builder->emit( 'shadow_pop', 'void', [] );
                $builder->emit( 'shadow_pop', 'void', [] );
                return ( $res, 'String' );
            }
            my ( $lr, $lt ) = $self->lower( $node->left );
            my ( $rr, $rt ) = $self->lower( $node->right );
            my $isf = ( $lt eq 'Float' || $rt eq 'Float' || $lt eq 'double' || $rt eq 'double' );
            my $mm  = { '+' => 'add', '-' => 'sub', '*' => 'mul', '/' => 'div', '%' => 'mod' };
            if ( exists $mm->{ $node->op } ) {
                if ($isf) { return ( $builder->emit( $mm->{ $node->op }, 'double', [ $lr, $rr ] ), 'Float' ) }
                my $res_raw = $builder->emit(
                    $mm->{ $node->op },
                    'i64',
                    [   $builder->emit( 'div', 'i64', [ $builder->emit( 'sub', 'i64', [ $lr, 1 ] ), 2 ] ),
                        $builder->emit( 'div', 'i64', [ $builder->emit( 'sub', 'i64', [ $rr, 1 ] ), 2 ] )
                    ]
                );
                return ( $builder->emit( 'add', 'i64', [ $builder->emit( 'mul', 'i64', [ $res_raw, 2 ] ), 1 ] ), 'Int' );
            }
            my $cm = { '==' => 'cmp_eq', '!=' => 'cmp_ne', '<' => 'cmp_lt', '>' => 'cmp_gt', '<=' => 'cmp_le', '>=' => 'cmp_ge' };
            if ( exists $cm->{ $node->op } ) {
                my $raw = $builder->emit( $cm->{ $node->op }, ( $isf ? 'double' : 'i64' ), [ $lr, $rr ] );
                return ( $builder->emit( 'add', 'i64', [ $builder->emit( 'mul', 'i64', [ $raw, 2 ] ), 1 ] ), 'Int' );
            }
            my $scm = { 'eq' => 'cmp_eq', 'ne' => 'cmp_ne', 'lt' => 'cmp_lt', 'gt' => 'cmp_gt', 'le' => 'cmp_le', 'ge' => 'cmp_ge' };
            if ( exists $scm->{ $node->op } ) {
                my $cmp_res = $builder->emit(
                    'call_func',
                    'i64',
                    [   'M_str_cmp',
                        ( $lt eq 'String' ? $lr : $builder->emit( 'call_func', 'ptr', [ 'M_any_to_str', $lr ] ) ),
                        ( $rt eq 'String' ? $rr : $builder->emit( 'call_func', 'ptr', [ 'M_any_to_str', $rr ] ) )
                    ]
                );
                my $raw = $builder->emit( $scm->{ $node->op }, 'i64', [ $cmp_res, 0 ] );
                return ( $builder->emit( 'add', 'i64', [ $builder->emit( 'mul', 'i64', [ $raw, 2 ] ), 1 ] ), 'Int' );
            }
            die "BinOp " . $node->op;
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
            my $sp = $builder->emit( 'shadow_get', 'ptr', [] );
            $current_scope = Brocken::Scope->new( parent => $current_scope );
            my $eh = scalar @defer_stack;
            my ( $r, $t );
            for my $s ( @{ $node->statements } ) { ( $r, $t ) = $self->lower($s) }
            while ( scalar @defer_stack > $eh ) {
                my $f = pop @defer_stack;
                for my $inst (@$f) { $builder->push_instruction($inst) }
            }
            $current_scope = $current_scope->parent;
            $builder->emit( 'shadow_set', 'void', [$sp] );
            return ( $r, $t );
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
            my $redo_l = $builder->new_label();
            my $next_l = $builder->new_label();    # Condition
            my $last_l = $builder->new_label();
            push @loop_stack, { next_l => $next_l, last_l => $last_l, redo_l => $redo_l };
            $builder->emit_jump($next_l);
            $builder->emit_label($redo_l);
            $self->lower( $node->body );
            $builder->emit_label($next_l);
            $builder->emit_cond_br( $self->_emit_bool_test( ( $self->lower( $node->condition ) )[0] ), $redo_l, $last_l );
            $builder->emit_label($last_l);
            pop @loop_stack;
            return ( undef, 'void' );
        }

        method lower_For($node) {

            # Protect loop variables within a dedicated lexical scope
            $current_scope = Brocken::Scope->new( parent => $current_scope );
            my $l_cond = $builder->new_label();
            my $l_next = $builder->new_label();
            my $l_redo = $builder->new_label();
            my $l_last = $builder->new_label();
            push @loop_stack, { next_l => $l_next, last_l => $l_last, redo_l => $l_redo };

            # Allocate local slots for loop variables at compile time
            my @vars = ref( $node->var ) eq 'ARRAY' ? @{ $node->var } : ( $node->var );
            my @var_slots;
            if ( $node->is_my ) {
                for my $vname (@vars) {
                    my $sl = $driver->alloc_local_slot();
                    $current_scope->define( $vname, 'Any', 0, undef, $sl );
                    push @var_slots, $sl;
                }
            }

            # --- 1. FAST PATH: ZERO-ALLOCATION RANGE ITERATION (e.g. `1 .. 1000000`) ---
            if ( $node->source isa Brocken::AST::Expr::BinOp && ( $node->source->op eq '..' || $node->source->op eq '...' ) ) {
                my ( $lr, $lt ) = $self->lower( $node->source->left );
                $builder->emit( 'shadow_push', 'void', [$lr] );
                my ( $rr, $rt ) = $self->lower( $node->source->right );
                $builder->emit( 'shadow_pop', 'void', [] );

                # Untag bounds
                my $l_val = $builder->emit( 'div', 'i64', [ $builder->emit( 'sub', 'i64', [ $lr, 1 ] ), 2 ] );
                my $r_val = $builder->emit( 'div', 'i64', [ $builder->emit( 'sub', 'i64', [ $rr, 1 ] ), 2 ] );
                if ( $node->source->op eq '...' ) {
                    $r_val = $builder->emit( 'sub', 'i64', [ $r_val, 1 ] );    # Exclusive range
                }
                my $idx_s = $driver->alloc_local_slot();
                $builder->emit( 'local_store', 'void', [ $idx_s, $l_val ] );
                my $limit_s = $driver->alloc_local_slot();
                $builder->emit( 'local_store', 'void', [ $limit_s, $r_val ] );
                $builder->emit_jump($l_cond);
                $builder->emit_label($l_redo);
                my $idx        = $builder->emit( 'local_load', 'i64', [$idx_s] );
                my $tagged_val = $builder->emit( 'or',         'i64', [ $builder->emit( 'shl', 'i64', [ $idx, 1 ] ), 1 ] );

                if ( $node->is_my ) {
                    $builder->emit( 'local_store', 'void', [ $var_slots[0], $tagged_val ] );

                    # Initialize any extra destructured vars to undef (useless for ranges, but safe)
                    for my $i ( 1 .. $#var_slots ) {
                        $builder->emit( 'local_store', 'void', [ $var_slots[$i], $builder->emit( 'load_data_addr', 'ptr', [$undef_ptr_offset] ) ] );
                    }
                }
                else {
                    my $s = $current_scope->resolve( $vars[0] );
                    if ($s) {
                        if ( defined $s->isolate_offset ) {
                            $builder->emit( 'store_iso_disp', 'void', [ $s->isolate_offset, $tagged_val ] );
                        }
                        else {
                            $builder->emit( 'local_store', 'void', [ $s->stack_offset, $tagged_val ] );
                        }
                    }
                }
                $self->lower( $node->body );
                $builder->emit_jump($l_next);
                $builder->emit_label($l_next);
                my $curr_idx = $builder->emit( 'local_load', 'i64', [$idx_s] );
                $builder->emit( 'local_store', 'void', [ $idx_s, $builder->emit( 'add', 'i64', [ $curr_idx, 1 ] ) ] );
                $builder->emit_jump($l_cond);
                $builder->emit_label($l_cond);
                my $chk_idx = $builder->emit( 'local_load', 'i64', [$idx_s] );
                my $limit   = $builder->emit( 'local_load', 'i64', [$limit_s] );
                $builder->emit_cond_br( $builder->emit( 'cmp_le', 'Int', [ $chk_idx, $limit ] ), $l_redo, $l_last );
                $builder->emit_label($l_last);
                pop @loop_stack;
                $current_scope = $current_scope->parent;
                return ( undef, 'void' );
            }

            # --- 2. DYNAMIC PATH: HASH & ARRAY ITERATION WITH DESTRUCTURING ---
            my ( $source_reg, $source_type ) = $self->lower( $node->source );
            $builder->emit( 'shadow_push', 'void', [$source_reg] );
            my $is_hash  = $builder->new_label();
            my $is_arr   = $builder->new_label();
            my $do_iter  = $builder->new_label();
            my $tag_word = $builder->emit( 'load_mem_disp', 'i64', [ $source_reg, 0 ] );
            my $type_tag = $builder->emit( 'and',           'i64', [ $tag_word,   3 ] );
            $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $type_tag, 3 ] ), $is_hash, $is_arr );

            # Hash Setup (Extract Keys Array dynamically)
            $builder->emit_label($is_hash);
            my $keys_arr   = $builder->emit( 'call_func', 'ptr', [ 'M_hash_keys', $source_reg ] );
            my $hash_src_s = $driver->alloc_local_slot();
            $builder->emit( 'local_store', 'void', [ $hash_src_s, $source_reg ] );
            my $iter_src_s = $driver->alloc_local_slot();
            $builder->emit( 'local_store', 'void', [ $iter_src_s, $keys_arr ] );

            # Push newly allocated keys array to shadow stack to protect it during iteration
            $builder->emit( 'shadow_push', 'void', [$keys_arr] );
            my $is_hash_s = $driver->alloc_local_slot();
            $builder->emit( 'local_store', 'void', [ $is_hash_s, 1 ] );
            $builder->emit_jump($do_iter);

            # Array Setup
            $builder->emit_label($is_arr);
            $builder->emit( 'local_store', 'void', [ $iter_src_s, $source_reg ] );
            $builder->emit( 'local_store', 'void', [ $is_hash_s,  0 ] );
            $builder->emit_jump($do_iter);
            $builder->emit_label($do_iter);
            my $idx_s = $driver->alloc_local_slot();
            $builder->emit( 'local_store', 'void', [ $idx_s, 0 ] );
            $builder->emit_jump($l_cond);
            $builder->emit_label($l_redo);
            my $arr             = $builder->emit( 'local_load', 'ptr', [$iter_src_s] );
            my $idx             = $builder->emit( 'local_load', 'i64', [$idx_s] );
            my $is_hash_flag    = $builder->emit( 'local_load', 'i64', [$is_hash_s] );
            my $num_vars        = scalar(@vars);
            my $l_destruct_hash = $builder->new_label();
            my $l_destruct_arr  = $builder->new_label();
            my $l_destruct_done = $builder->new_label();
            $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $is_hash_flag, 1 ] ), $l_destruct_hash, $l_destruct_arr );

            # --- Extract Hash Element ---
            $builder->emit_label($l_destruct_hash);
            my $k_ptr = $builder->emit( 'add', 'ptr', [ $arr, $builder->emit( 'add', 'i64', [ 8, $builder->emit( 'mul', 'i64', [ $idx, 8 ] ) ] ) ] );
            my $k_val = $builder->emit( 'load_mem_disp', 'Any', [ $k_ptr, 0 ] );
            my $v_val;
            if ( $num_vars > 1 ) {
                my $hash_obj = $builder->emit( 'local_load', 'ptr', [$hash_src_s] );
                $v_val = $builder->emit( 'call_func', 'Any', [ 'M_hash_lookup', $hash_obj, $k_val ] );
            }
            if ( $node->is_my ) {
                $builder->emit( 'local_store', 'void', [ $var_slots[0], $k_val ] );
                if ( $num_vars > 1 ) {
                    $builder->emit( 'local_store', 'void', [ $var_slots[1], $v_val ] );
                }

                # Undefine any extra vars
                for my $i ( 2 .. $#vars ) {
                    $builder->emit( 'local_store', 'void', [ $var_slots[$i], $builder->emit( 'load_data_addr', 'ptr', [$undef_ptr_offset] ) ] );
                }
            }
            else {
                my $s = $current_scope->resolve( $vars[0] );
                $builder->emit( 'local_store', 'void', [ $s->stack_offset, $k_val ] ) if $s;
                if ( $num_vars > 1 ) {
                    my $s2 = $current_scope->resolve( $vars[1] );
                    $builder->emit( 'local_store', 'void', [ $s2->stack_offset, $v_val ] ) if $s2;
                }
            }
            $builder->emit_jump($l_destruct_done);

            # --- Extract Array Element(s) ---
            $builder->emit_label($l_destruct_arr);
            my $raw_len = $builder->emit( 'load_mem_disp', 'i64', [ $arr,     0 ] );
            my $len     = $builder->emit( 'shr',           'i64', [ $raw_len, 2 ] );
            for my $v_idx ( 0 .. $num_vars - 1 ) {
                my $cur_elem_idx = $builder->emit( 'add', 'i64', [ $idx, $v_idx ] );
                my $l_in_bounds  = $builder->new_label();
                my $l_oob        = $builder->new_label();
                my $l_val_ready  = $builder->new_label();
                my $val_s        = $driver->alloc_local_slot();
                $builder->emit_cond_br( $builder->emit( 'cmp_lt', 'Int', [ $cur_elem_idx, $len ] ), $l_in_bounds, $l_oob );
                $builder->emit_label($l_in_bounds);
                my $ptr = $builder->emit( 'add', 'ptr',
                    [ $arr, $builder->emit( 'add', 'i64', [ 8, $builder->emit( 'mul', 'i64', [ $cur_elem_idx, 8 ] ) ] ) ] );
                $builder->emit( 'local_store', 'void', [ $val_s, $builder->emit( 'load_mem_disp', 'Any', [ $ptr, 0 ] ) ] );
                $builder->emit_jump($l_val_ready);
                $builder->emit_label($l_oob);
                $builder->emit( 'local_store', 'void', [ $val_s, $builder->emit( 'load_data_addr', 'ptr', [$undef_ptr_offset] ) ] );
                $builder->emit_jump($l_val_ready);
                $builder->emit_label($l_val_ready);

                if ( $node->is_my ) {
                    $builder->emit( 'local_store', 'void', [ $var_slots[$v_idx], $builder->emit( 'local_load', 'Any', [$val_s] ) ] );
                }
                else {
                    my $s = $current_scope->resolve( $vars[$v_idx] );
                    if ($s) {
                        if ( defined $s->isolate_offset ) {
                            $builder->emit( 'store_iso_disp', 'void', [ $s->isolate_offset, $builder->emit( 'local_load', 'Any', [$val_s] ) ] );
                        }
                        else {
                            $builder->emit( 'local_store', 'void', [ $s->stack_offset, $builder->emit( 'local_load', 'Any', [$val_s] ) ] );
                        }
                    }
                }
            }
            $builder->emit_jump($l_destruct_done);
            $builder->emit_label($l_destruct_done);

            # Execute Loop Body
            $self->lower( $node->body );

            # Fallthrough to increment
            $builder->emit_jump($l_next);
            $builder->emit_label($l_next);
            my $curr_idx   = $builder->emit( 'local_load', 'i64', [$idx_s] );
            my $l_inc_hash = $builder->new_label();
            my $l_inc_arr  = $builder->new_label();
            my $l_inc_done = $builder->new_label();
            $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $builder->emit( 'local_load', 'i64', [$is_hash_s] ), 1 ] ),
                $l_inc_hash, $l_inc_arr );
            $builder->emit_label($l_inc_hash);
            $builder->emit( 'local_store', 'void', [ $idx_s, $builder->emit( 'add', 'i64', [ $curr_idx, 1 ] ) ] );
            $builder->emit_jump($l_inc_done);
            $builder->emit_label($l_inc_arr);
            my $stride_val = ref( $node->var ) eq 'ARRAY' ? scalar( @{ $node->var } ) : 1;
            $builder->emit( 'local_store', 'void', [ $idx_s, $builder->emit( 'add', 'i64', [ $curr_idx, $stride_val ] ) ] );
            $builder->emit_jump($l_inc_done);
            $builder->emit_label($l_inc_done);
            $builder->emit_jump($l_cond);

            # --- Loop Condition Verification ---
            $builder->emit_label($l_cond);
            my $arr_for_len = $builder->emit( 'local_load',    'ptr', [$iter_src_s] );
            my $raw_len2    = $builder->emit( 'load_mem_disp', 'i64', [ $arr_for_len, 0 ] );
            my $len2        = $builder->emit( 'shr',           'i64', [ $raw_len2,    2 ] );
            my $chk_idx     = $builder->emit( 'local_load',    'i64', [$idx_s] );
            $builder->emit_cond_br( $builder->emit( 'cmp_lt', 'Int', [ $chk_idx, $len2 ] ), $l_redo, $l_last );
            $builder->emit_label($l_last);

            # Pop shadow stack (If hash, pop keys array. Original source gets popped right after)
            my $l_pop_hash = $builder->new_label();
            my $l_pop_done = $builder->new_label();
            $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $builder->emit( 'local_load', 'i64', [$is_hash_s] ), 1 ] ),
                $l_pop_hash, $l_pop_done );
            $builder->emit_label($l_pop_hash);
            $builder->emit( 'shadow_pop', 'void', [] );    # Pop keys array
            $builder->emit_jump($l_pop_done);
            $builder->emit_label($l_pop_done);
            $builder->emit( 'shadow_pop', 'void', [] );    # Pop original source
            pop @loop_stack;
            $current_scope = $current_scope->parent;       # End loop lexical scope
            return ( undef, 'void' );
        }

        method lower_Next($node) {
            die "No active loop" unless @loop_stack;
            $builder->emit_jump( $loop_stack[-1]{next_l} );
            return ( undef, 'void' );
        }

        method lower_Last($node) {
            die "No active loop" unless @loop_stack;
            $builder->emit_jump( $loop_stack[-1]{last_l} );
            return ( undef, 'void' );
        }

        method lower_Redo($node) {
            die "No active loop" unless @loop_stack;
            $builder->emit_jump( $loop_stack[-1]{redo_l} );
            return ( undef, 'void' );
        }

        method lower_Call($node) {
            if ( $node->name eq 'make_callback' ) {
                my $sub_expr = $node->args->[0];
                my $sig_expr = $node->args->[1];
                die "make_callback requires a static signature string" unless $sig_expr isa Brocken::AST::Expr::Const && $sig_expr->type eq 'String';
                my $sig_str = $sig_expr->value;
                my ( $sub_reg, $sub_type ) = $self->lower($sub_expr);
                my $pool_id   = $self->_get_or_create_callback_pool($sig_str);
                my $tramp_ptr = $builder->emit( 'call_func', 'ptr', [ "M_reserve_callback_" . $pool_id, $sub_reg ] );
                return ( $tramp_ptr, 'ptr' );
            }
            if ( $node->name eq 'transfer' ) {
                return (
                    $builder->emit(
                        'call_func', 'Int', [ 'M_fiber_switch', ( $self->lower( $node->args->[0] ) )[0], ( $self->lower( $node->args->[1] ) )[0] ]
                    ),
                    'Any'
                );
            }
            if ( $node->name eq 'sleep' ) {
                $builder->emit( 'intrinsic_sleep', 'void',
                    [ ( $self->lower( $node->args->[0] // Brocken::AST::Expr::Const->new( value => 1, type => 'Int' ) ) )[0] ] );
                return ( undef, 'void' );
            }
            if ( $node->name eq 'open' ) {
                my ($path_reg) = $self->lower( $node->args->[0] // die "open requires a path" );
                my ($mode_reg) = $self->lower( $node->args->[1] // Brocken::AST::Expr::Const->new( value => "r", type => 'String' ) );
                my $fd         = $builder->emit( 'intrinsic_open', 'i64', [ $path_reg, $mode_reg ] );
                my $obj
                    = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', $builder->emit( 'constant', 'i64', [ 32 | hex("C000000000000000") ] ) ] );
                $builder->emit( 'store_mem_disp', 'void', [ $obj, 8, $fd ] );
                $builder->emit( 'shadow_push',    'void', [$obj] );
                return ( $obj, 'FileHandle' );
            }
            if ( $node->name eq 'close' ) {
                $builder->emit( 'intrinsic_close', 'void',
                    [ $builder->emit( 'load_mem_disp', 'i64', [ ( $self->lower( $node->args->[0] ) )[0], 8 ] ) ] );
                return ( undef, 'void' );
            }
            if ( $node->name eq 'refcount' ) {
                my ( $r, $t ) = $self->lower( $node->args->[0] );

                # Load the 64-bit object header at offset -8
                my $hdr = $builder->emit( 'load_mem_disp', 'i64', [ $r, -8 ] );

                # The Reference Count lives in bits 48..60.
                # We shift right 48 bits, then mask with 0x1FFF (13 bits).
                my $rc = $builder->emit( 'and', 'i64', [ $builder->emit( 'shr', 'i64', [ $hdr, 48 ] ), 0x1FFF ] );

                # Tag it as a Brocken Int: (val << 1) | 1
                return ( $builder->emit( 'or', 'i64', [ $builder->emit( 'shl', 'i64', [ $rc, 1 ] ), 1 ] ), 'Int' );
            }
            if ( $node->name eq 'retain' ) {
                my ( $r, $t ) = $self->lower( $node->args->[0] );
                $builder->emit( 'local_inc_ref', 'void', [$r] );
                return ( undef, 'void' );
            }
            if ( $node->name eq 'release' ) {
                my ( $r, $t ) = $self->lower( $node->args->[0] );
                $builder->emit( 'local_dec_ref', 'void', [$r] );
                return ( undef, 'void' );
            }
            if ( $node->name eq 'slurp' ) {
                my ($path_reg) = $self->lower( $node->args->[0] );
                my $fd = $builder->emit( 'intrinsic_open', 'i64',
                    [ $path_reg, $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string("r") ] ) ] );
                my $size    = $builder->emit( 'intrinsic_get_size', 'i64', [$fd] );
                my $str_obj = $builder->emit( 'call_func', 'ptr',
                    [ 'M_gc_alloc', $builder->emit( 'or', 'i64', [ $builder->emit( 'add', 'i64', [ $size, 16 ] ), hex("C000000000000000") ] ) ] );
                $builder->emit( 'store_mem_disp',  'void', [ $str_obj, 0, $size ] );
                $builder->emit( 'intrinsic_read',  'i64',  [ $fd, $builder->emit( 'add', 'ptr', [ $str_obj, 16 ] ), $size ] );
                $builder->emit( 'intrinsic_close', 'void', [$fd] );
                return ( $str_obj, 'String' );
            }
            if ( $node->name eq 'print' ) {
                if ( scalar @{ $node->args } > 1 ) {
                    my ($fh_reg) = $self->lower( $node->args->[0] );
                    my ( $val_reg, $val_type ) = $self->lower( $node->args->[1] );
                    my $fd  = $builder->emit( 'load_mem_disp', 'i64', [ $fh_reg, 8 ] );
                    my $str = $val_type eq 'String' ? $val_reg : $builder->emit( 'call_func', 'ptr', [ 'M_any_to_str', $val_reg ] );
                    $builder->emit( 'intrinsic_write', 'void',
                        [ $fd, $builder->emit( 'add', 'ptr', [ $str, 16 ] ), $builder->emit( 'load_mem_disp', 'i64', [ $str, 0 ] ) ] );
                }
                else {
                    my ( $r, $t ) = $self->lower( $node->args->[0] );
                    if   ( $t eq 'String' ) { $builder->emit( 'intrinsic_print', 'void', [$r] ); }
                    else                    { $builder->emit( 'call_func',       'void', [ 'M_print_any', $r ] ); }
                }
                return ( undef, 'void' );
            }
            if ( $node->name eq 'say' ) {
                my ( $r, $t ) = $self->lower( $node->args->[0] );
                if   ( $t eq 'String' ) { $builder->emit( 'intrinsic_print', 'void', [$r] ) }
                else                    { $builder->emit( 'call_func',       'void', [ "M_print_any", $r ] ) }
                $builder->emit( 'intrinsic_print', 'void', [ $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string("\n") ] ) ] );
                return ( undef, 'void' );
            }
            if ( $node->name eq 'ddx' ) {
                my $first = 1;
                for my $arg ( @{ $node->args } ) {
                    my ( $r, $t ) = $self->lower($arg);
                    if ($first) { $first = 0 }
                    else {
                        $builder->emit( 'intrinsic_print_stderr', 'void',
                            [ $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string(" ") ] ) ] );
                    }
                    $builder->emit( 'call_func', 'void', [ 'M_ddx_val', $r, $builder->emit( 'constant', 'i64', [1] ) ] );
                }
                $builder->emit( 'intrinsic_print_stderr', 'void',
                    [ $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string("\n") ] ) ] );
                return ( undef, 'void' );
            }
            if ( $node->name eq 'dd' ) {
                my ( $r, $t ) = $self->lower( $node->args->[0] );
                return ( $builder->emit( 'call_func', 'ptr', [ 'M_dd', $r ] ), 'String' );
            }
            if ( $node->name eq 'keys' ) {
                return ( $builder->emit( 'call_func', 'ptr', [ 'M_hash_keys', ( $self->lower( $node->args->[0] ) )[0] ] ), 'Array' );
            }
            if ( $node->name eq 'values' ) {
                return ( $builder->emit( 'call_func', 'ptr', [ 'M_hash_values', ( $self->lower( $node->args->[0] ) )[0] ] ), 'Array' );
            }
            my @as;
            my $sp_backup = $builder->emit( 'shadow_get', 'ptr', [] );
            for my $arg ( @{ $node->args } ) {
                my ( $r, $t ) = $self->lower($arg);
                push @as, $r;

                # Always push pointers to shadow stack to protect them during function invocation
                if ( $t =~ /^(Any|String|Array|Hash|Tuple|Fiber|Class|Undef)$/ || $t !~ /^(Int|Float|i64|double|ptr|void)$/ ) {
                    $builder->emit( 'shadow_push', 'void', [$r] );
                }
            }
            my $res = $builder->emit( 'call_func', 'i64', [ "M_" . $node->name, @as ] );
            $builder->emit( 'shadow_set', 'void', [$sp_backup] );
            return ( $res, 'Any' );
        }

        method lower_Defer($node) {
            my @saved_instructions = $builder->instructions;
            $builder->set_instructions();
            $defer_active_depth++;
            $self->lower( $node->block );
            $defer_active_depth--;
            my @deferred_instructions = $builder->instructions;
            $builder->set_instructions(@saved_instructions);
            push @defer_stack, \@deferred_instructions;
            return ( undef, 'void' );
        }

        method lower_Return($node) {
            die "Semantic Error: 'return' is not allowed inside a defer block.\n" if $defer_active_depth > 0;
            my ($rv) = defined $node->expr ? $self->lower( $node->expr ) : ( $builder->emit( 'constant', 'i64', [1] ), 'Int' );

            # Protect RV from GC while defers run
            $builder->emit( 'shadow_push', 'void', [$rv] );
            $self->_emit_all_defers();
            if ( $routine_types[-1] eq 'fiber' ) {
                $builder->emit(
                    'call_func',
                    'Any',
                    [   'M_fiber_switch',
                        $builder->emit(
                            'load_mem_disp', 'ptr',
                            [ $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('current_fcb') ] ), $driver->fcb_offset('caller') ]
                        ),
                        $rv
                    ]
                );
                $builder->emit( 'intrinsic_exit', 'void', [0] );
            }
            else {
                # Pop value just before leaving
                $rv = $builder->emit( 'shadow_pop', 'ptr', [] );
                $builder->emit( 'leave_func', 'void', [$rv] );
            }
            return ( undef, 'void' );
        }

        method lower_Exit($node) {
            $self->_emit_all_defers();
            $builder->emit( 'intrinsic_exit', 'void',
                [ defined $node->expr ? ( $self->lower( $node->expr ) )[0] : $builder->emit( 'constant', 'i64', [1] ) ] );
            return ( undef, 'void' );
        }

        method lower_Die($node) {
            $self->_emit_all_defers();
            $builder->emit( 'intrinsic_throw', 'void',
                [ $node->exception ? ( $self->lower( $node->exception ) )[0] : $builder->emit( 'constant', 'i64', [1] ) ] );
            return ( undef, 'void' );
        }

        method lower_TryCatch($node) {
            my $try_id    = ++$anon_counter;
            my $l_catch   = $builder->new_label();
            my $l_end     = $builder->new_label();
            my $l_finally = $node->finally_block ? $builder->new_label() : undef;
            $builder->emit( 'mark_try_start', 'void', [ $try_id, $l_catch, $l_finally ] );
            $self->lower( $node->try_block );
            $builder->emit( 'mark_try_end', 'void', [$try_id] );
            $builder->emit_jump( $l_finally // $l_end );
            $builder->emit_label($l_catch);
            my $exc = $builder->emit( 'intrinsic_get_exception', 'Any', [] );
            $builder->emit( 'intrinsic_clear_exception', 'void', [] );
            $current_scope = Brocken::Scope->new( parent => $current_scope );
            my $sl = $driver->alloc_local_slot();
            $current_scope->define( $node->catch_var->{value}, 'Any', 0, undef, $sl );
            $builder->emit( 'local_store', 'void', [ $sl, $exc ] );
            $self->lower( $node->catch_block );
            $current_scope = $current_scope->parent;
            $builder->emit_jump( $l_finally // $l_end );
            if ($l_finally) { $builder->emit_label($l_finally); $self->lower( $node->finally_block ); }
            $builder->emit_label($l_end);
            return ( undef, 'void' );
        }

        method lower_MethodCall($node) {
            my $inv = $node isa Brocken::AST::Expr::MethodCall ? $node->object : $node->invocant;
            my $mn  = $node isa Brocken::AST::Expr::MethodCall ? $node->method : $node->name;
            if ( $mn eq 'new' && $inv isa Brocken::AST::Expr::Const && $inv->type eq 'Class' ) {
                my $res = $builder->emit( 'call_func', 'ptr', [ "M_" . $inv->value . "::new" ] );
                $builder->emit( 'shadow_push', 'void', [$res] );
                return ( $res, $inv->value );
            }
            my $sp_backup = $builder->emit( 'shadow_get', 'ptr', [] );
            my ( $or, $ot ) = $self->lower($inv);

            # Protect invocant
            $builder->emit( 'shadow_push', 'void', [$or] );
            my @as;
            for my $arg ( @{ $node->args } ) {
                my ( $r, $t ) = $self->lower($arg);
                push @as, $r;

                # Protect arguments
                if ( $t =~ /^(Any|String|Array|Hash|Tuple|Fiber|Class|Undef)$/ || $t !~ /^(Int|Float|i64|double|ptr|void)$/ ) {
                    $builder->emit( 'shadow_push', 'void', [$r] );
                }
            }
            if ( $ot eq 'Fiber' && $mn eq 'switch' ) {
                my $res = $builder->emit( 'call_func', 'Any', [ 'M_fiber_switch', $or, @as ] );
                $builder->emit( 'shadow_set', 'void', [$sp_backup] );
                return ( $res, 'Any' );
            }
            my $l_not_null = $builder->new_label();
            $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $or, 0 ] ), $builder->new_label(), $l_not_null );
            $builder->emit_label( $builder->last_instruction->{true_l} );
            $builder->emit( 'intrinsic_throw', 'void', [255] );
            $builder->emit_label($l_not_null);
            my $res = $builder->emit(
                'call_reg',
                'i64',
                [   $builder->emit(
                        'load_mem_disp', 'ptr',
                        [ $builder->emit( 'load_mem_disp', 'ptr', [ $or, 0 ] ), ( $global_methods{$mn} // die "Unknown method '$mn'" ) * 8 ]
                    ),
                    $or, @as
                ]
            );
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
            }
            my ($res) = $self->lower_block( $node->body->statements );
            $self->_emit_all_defers();
            $builder->emit(
                'call_func',
                'Any',
                [   'M_fiber_switch',
                    $builder->emit(
                        'load_mem_disp', 'ptr',
                        [ $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('current_fcb') ] ), $driver->fcb_offset('caller') ]
                    ),
                    $res // 3
                ]
            );
            $builder->emit( 'intrinsic_exit', 'void', [0] );
            $self->_flush_func_locals();
            pop @routine_types;
            $routine_depth--;
            $current_scope     = $current_scope->parent;
            @defer_stack       = @old_defers;
            $current_func_name = $saved_func_name;
            @func_locals       = @saved_func_locals;
            my @ir = $builder->instructions;
            $builder->set_instructions( @saved, @ir );
            $builder->emit_label($l2);
            $driver->set_local_ptr($op);
            return ( $builder->emit( 'call_func', 'ptr', [ 'M_fiber_new', $l1 ] ), 'Fiber' );
        }

        method lower_Yield($node) {
            return (
                $builder->emit(
                    'call_func',
                    'Int',
                    [   'M_fiber_switch',
                        $builder->emit(
                            'load_mem_disp', 'ptr',
                            [ $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('current_fcb') ] ), $driver->fcb_offset('caller') ]
                        ),
                        defined $node->expr ? ( $self->lower( $node->expr ) )[0] : $builder->emit( 'constant', 'i64', [1] )
                    ]
                ),
                'Int'
            );
        }

        method lower_ArrayLiteral($node) {
            my $ct  = scalar @{ $node->elements };
            my $arr = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', $builder->emit( 'constant', 'i64', [ 8 + $ct * 8 ] ) ] );
            $builder->emit( 'shadow_push',    'void', [$arr] );
            $builder->emit( 'store_mem_disp', 'void', [ $arr, 0, $builder->emit( 'constant', 'i64', [ ( $ct << 2 ) | 1 ] ) ] );
            my $ix = 0;
            for my $el ( @{ $node->elements } ) {
                my ( $vr, $vt ) = $self->lower($el);
                my $off = 8 + ( $ix++ * 8 );
                if ( $vt =~ /^(Any|String|Array|Fiber|Class|Undef)$/ || $vt !~ /^(Int|Float|i64|double|ptr|void)$/ ) {
                    $self->_emit_write_barrier( $arr, $off, $vr );
                }
                else { $builder->emit( 'store_mem_disp', 'void', [ $arr, $off, $vr ] ); }
            }
            $builder->emit( 'shadow_pop', 'void', [] );
            return ( $arr, 'Array' );
        }

        method lower_TupleLiteral($node) {
            my $ct  = scalar @{ $node->elements };
            my $tup = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', $builder->emit( 'constant', 'i64', [ 8 + $ct * 8 ] ) ] );
            $builder->emit( 'shadow_push',    'void', [$tup] );
            $builder->emit( 'store_mem_disp', 'void', [ $tup, 0, $builder->emit( 'constant', 'i64', [ ( $ct << 2 ) | 2 ] ) ] );
            my $ix = 0;
            for my $el ( @{ $node->elements } ) {
                my ( $vr, $vt ) = $self->lower($el);
                my $off = 8 + ( $ix++ * 8 );
                if ( $vt =~ /^(Any|String|Array|Hash|Tuple|Fiber|Class|Undef)$/ || $vt !~ /^(Int|Float|i64|double|ptr|void)$/ ) {
                    $self->_emit_write_barrier( $tup, $off, $vr );
                }
                else { $builder->emit( 'store_mem_disp', 'void', [ $tup, $off, $vr ] ); }
            }
            $builder->emit( 'shadow_pop', 'void', [] );
            return ( $tup, 'Tuple' );
        }

        method lower_HashLiteral($node) {
            my $hash = $builder->emit( 'call_func', 'ptr', ['M_hash_new'] );
            $builder->emit( 'shadow_push', 'void', [$hash] );
            for my $pair ( @{ $node->pairs } ) {
                my ( $kr, $kt ) = $self->lower( $pair->{key} );
                $builder->emit( 'shadow_push', 'void', [$kr] );
                my ( $vr, $vt ) = $self->lower( $pair->{value} );
                $builder->emit( 'call_func', 'void',
                    [ 'M_hash_insert', $hash, ( $kt eq 'String' ? $kr : $builder->emit( 'call_func', 'ptr', [ 'M_any_to_str', $kr ] ) ), $vr ] );
                $builder->emit( 'shadow_pop', 'void', [] );
            }
            $builder->emit( 'shadow_pop', 'void', [] );
            return ( $hash, 'Hash' );
        }

        method lower_IndexExpr($node) {
            my ($src_reg) = $self->lower( $node->source );
            my $l_not_null = $builder->new_label();
            $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $src_reg, 0 ] ), $builder->new_label(), $l_not_null );
            $builder->emit_label( $builder->last_instruction->{true_l} );
            $builder->emit( 'intrinsic_throw', 'void', [255] );
            $builder->emit_label($l_not_null);
            $builder->emit( 'shadow_push', 'void', [$src_reg] );
            my ( $idx_reg, $idx_type ) = $self->lower( $node->index );
            my $res_slot  = $driver->alloc_local_slot();
            my $l_is_hash = $builder->new_label();
            my $l_is_arr  = $builder->new_label();
            my $l_end     = $builder->new_label();
            my $type_tag  = $builder->emit( 'and', 'i64', [ $builder->emit( 'load_mem_disp', 'i64', [ $src_reg, 0 ] ), 3 ] );
            $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $type_tag, 3 ] ), $l_is_hash, $l_is_arr );

            # --- Array Path ---
            $builder->emit_label($l_is_arr);
            my $raw_idx = $builder->emit( 'shr', 'i64', [ $idx_reg, 1 ] );

            # Bounds Check: Get array count from tag_word
            my $tag_word        = $builder->emit( 'load_mem_disp', 'i64', [ $src_reg,  0 ] );
            my $count           = $builder->emit( 'shr',           'i64', [ $tag_word, 2 ] );
            my $l_in_bounds     = $builder->new_label();
            my $l_out_of_bounds = $builder->new_label();
            my $is_ge           = $builder->emit( 'cmp_ge', 'Int', [ $raw_idx, $count ] );
            my $is_lt0          = $builder->emit( 'cmp_lt', 'Int', [ $raw_idx, 0 ] );
            my $is_oob          = $builder->emit( 'or',     'i64', [ $is_ge,   $is_lt0 ] );
            $builder->emit_cond_br( $is_oob, $l_out_of_bounds, $l_in_bounds );

            # In Bounds: Load element
            $builder->emit_label($l_in_bounds);
            my $addr = $builder->emit( 'add', 'ptr',
                [ $builder->emit( 'add', 'ptr', [ $src_reg, 8 ] ), $builder->emit( 'mul', 'i64', [ $raw_idx, 8 ] ) ] );
            my $raw_val = $builder->emit( 'load_mem_disp', 'Any', [ $addr, 0 ] );

            # If the loaded value is 0 (uninitialized), replace it with the undef pointer
            my $l_raw_null = $builder->new_label();
            my $l_raw_ok   = $builder->new_label();
            $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $raw_val, 0 ] ), $l_raw_null, $l_raw_ok );
            $builder->emit_label($l_raw_null);
            $builder->emit( 'local_store', 'void', [ $res_slot, $builder->emit( 'load_data_addr', 'ptr', [$undef_ptr_offset] ) ] );
            $builder->emit_jump($l_end);
            $builder->emit_label($l_raw_ok);
            $builder->emit( 'local_store', 'void', [ $res_slot, $raw_val ] );
            $builder->emit_jump($l_end);

            # Out of Bounds: Return undef pointer
            $builder->emit_label($l_out_of_bounds);
            $builder->emit( 'local_store', 'void', [ $res_slot, $builder->emit( 'load_data_addr', 'ptr', [$undef_ptr_offset] ) ] );
            $builder->emit_jump($l_end);

            # --- Hash Path ---
            $builder->emit_label($l_is_hash);
            $builder->emit(
                'local_store',
                'void',
                [   $res_slot,
                    $builder->emit(
                        'call_func',
                        'Any',
                        [   'M_hash_lookup', $src_reg,
                            ( $idx_type eq 'String' ? $idx_reg : $builder->emit( 'call_func', 'ptr', [ 'M_any_to_str', $idx_reg ] ) )
                        ]
                    )
                ]
            );
            $builder->emit_jump($l_end);
            $builder->emit_label($l_end);
            $builder->emit( 'shadow_pop', 'void', [] );
            return ( $builder->emit( 'local_load', 'Any', [$res_slot] ), 'Any' );
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
            my ( $invocant_reg, $invocant_type ) = $self->lower( $node->invocant );
            my $is_c_callback = ( $invocant_type =~ /^Callback/ );
            my @processed_args;
            for my $arg ( @{ $node->args } ) {
                my ($arg_reg) = $self->lower($arg);
                push @processed_args, ( $is_c_callback ? $builder->emit( 'shr', 'i64', [ $arg_reg, 1 ] ) : $arg_reg );
            }
            my $res = $builder->emit( 'call_reg', 'i64', [ $invocant_reg, @processed_args ] );
            if ($is_c_callback) {
                $res = $builder->emit( 'or', 'i64',
                    [ $builder->emit( 'shl', 'i64', [ $builder->emit( 'and', 'i64', [ $res, 0xFFFFFFFF ] ), 1 ] ), 1 ] );
            }
            return ( $res, 'Any' );
        }
        method lower_Eval($node) { die "Eval is disabled.\n"; }

        method lower_Yada($node) {
            my $msg = $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string("Unimplemented ...") ] );

            # Store the message in the FCB so M_unwind can find it
            my $fcb = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('current_fcb') ] );
            $builder->emit( 'store_mem_disp', 'void', [ $fcb, $driver->fcb_offset('exception_obj'), $msg ] );

            # Call unwind with 0 arguments
            $builder->emit( 'call_func', 'void', ['M_unwind'] );
            return ( undef, 'void' );
        }
        method lower_Use($node) { return $self->lower_Require($node); }

        method lower_Require($node) {
            my $package = $node->package;
            ( my $filename = $package ) =~ s|::|/|g;
            $filename .= ".brocken";
            my $path;
            for my $dir ( '.', 'lib' ) {
                if ( -f "$dir/$filename" ) { $path = "$dir/$filename"; last; }
            }
            die "Module $package not found" unless $path;
            open my $fh, '<', $path or die $!;
            my $source = do { local $/; <$fh> };
            close $fh;
            my $ast = Brocken::Parser->new( tokens => Brocken::Lexer->new( source => $source )->lex() )->parse();
            $self->register_classes($ast);
            my @main_stmts;

            for my $n (@$ast) {
                if   ( $n isa Brocken::AST::OOP::Method || $n isa Brocken::AST::OOP::ClassDecl ) { $self->lower($n); }
                else                                                                             { push @main_stmts, $n; }
            }
            for my $stmt (@main_stmts) { $self->lower($stmt); }
            return ( $builder->emit( 'constant', 'i64', [1] ), 'Int' );
        }

        method lower_Method($node) {
            $driver->reset_locals();
            @defer_stack = ();
            my $fn = 'M_' . $node->name;
            $builder->emit_label($fn);
            $builder->emit( 'enter_func', 'void', [] );
            $current_scope = Brocken::Scope->new( parent => $current_scope );
            $routine_depth++;
            my $ai = 0;

            for my $p ( @{ $node->params } ) {
                my $l = $driver->alloc_local_slot();
                $current_scope->define( $p->{name}, $p->{type}, 0, undef, $l );
                $builder->emit( 'local_store', 'void', [ $l, $builder->emit( 'get_arg', 'i64', [ $ai++ ] ) ] );
            }
            $self->lower_block( $node->body->statements );
            $self->_emit_all_defers();
            $builder->emit( 'leave_func', 'void', [0] );
            $routine_depth--;
            $current_scope = $current_scope->parent;
            push @exported_funcs, $node->name;
            $self->_generate_export_thunk($node);
            return ( undef, 'void' );
        }

        method lower_ClassDecl($node) {
            my $ci  = $class_info{ $node->name };
            my $off = $ci->{field_end_offset};
            $driver->reset_locals();
            $builder->emit_label( "M_" . $node->name . "::new" );
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
            my $field_offset = 16;

            if ( defined $ci->{parent_class} ) {
                $field_offset = $class_info{ $ci->{parent_class} }{field_end_offset};
            }
            for my $f ( @{ $node->fields } ) {
                ( my $clean_name = $f->name ) =~ s/^[\$@%]//;
                $driver->reset_locals();
                $builder->emit_label( "M_" . $node->name . "::" . $clean_name );
                $builder->emit( 'enter_func', 'void', [] );
                my $self_ptr   = $builder->emit( 'get_arg', 'ptr', [0] );
                my $l_not_null = $builder->new_label();
                $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $self_ptr, 0 ] ), $builder->new_label(), $l_not_null );
                $builder->emit_label( $builder->last_instruction->{true_l} );
                $builder->emit( 'intrinsic_throw', 'void', [255] );
                $builder->emit_label($l_not_null);
                $builder->emit( 'leave_func', 'Any', [ $builder->emit( 'load_mem_disp', 'Any', [ $self_ptr, $field_offset ] ) ] );
                $driver->reset_locals();
                $builder->emit_label( "M_" . $node->name . "::set_" . $clean_name );
                $builder->emit( 'enter_func', 'void', [] );
                $self_ptr = $builder->emit( 'get_arg', 'ptr', [0] );
                my $l_not_null_s = $builder->new_label();
                $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $self_ptr, 0 ] ), $builder->new_label(), $l_not_null_s );
                $builder->emit_label( $builder->last_instruction->{true_l} );
                $builder->emit( 'intrinsic_throw', 'void', [255] );
                $builder->emit_label($l_not_null_s);
                my $new_val = $builder->emit( 'get_arg', 'Any', [1] );

                if ( $f->type =~ /^(Any|String|Array|Hash|Tuple|Fiber|Class|Undef)$/ || $f->type !~ /^(Int|Float|i64|double|ptr|void)$/ ) {
                    $self->_emit_write_barrier( $self_ptr, $field_offset, $new_val );
                }
                else { $builder->emit( 'store_mem_disp', 'void', [ $self_ptr, $field_offset, $new_val ] ); }
                $builder->emit( 'leave_func', 'void', [] );
                $field_offset += 8;
            }
            for my $m ( @{ $node->methods } ) {
                $driver->reset_locals();
                @defer_stack = ();
                my $fn_name = "M_" . $node->name . "::" . $m->name;
                $builder->emit_label($fn_name);
                $builder->emit( 'enter_func', 'void', [] );
                $current_scope = Brocken::Scope->new( parent => $current_scope );
                $routine_depth++;
                my $ss = $driver->alloc_local_slot();
                $current_scope->define( '$self', 'ptr', 0, undef, $ss );
                $builder->emit( 'local_store', 'void', [ $ss, $builder->emit( 'get_arg', 'ptr', [0] ) ] );
                my $ai = 1;
                my $fo = 16;
                my @ancestors;
                my $curr = $ci->{parent_class};

                while ( defined $curr ) {
                    unshift @ancestors, $curr;
                    $curr = $class_info{$curr}{parent_class};
                }
                for my $anc (@ancestors) {
                    for my $field ( @{ $class_info{$anc}{fields} } ) {
                        $current_scope->define( $field->name, 'Any', 0, undef, -$fo );
                        $fo += 8;
                    }
                }
                for my $field ( @{ $node->fields } ) { $current_scope->define( $field->name, 'Any', 0, undef, -$fo ); $fo += 8 }
                for my $p     ( @{ $m->params } ) {
                    my $l = $driver->alloc_local_slot();
                    $current_scope->define( $p->{name}, $p->{type}, 0, undef, $l );
                    $builder->emit( 'local_store', 'void', [ $l, $builder->emit( 'get_arg', 'i64', [ $ai++ ] ) ] );
                }
                $self->lower_block( $m->body->statements );
                $self->_emit_all_defers();
                $builder->emit( 'leave_func', 'void', [0] );
                $routine_depth--;
                $current_scope = $current_scope->parent;
                push @exported_funcs, $node->name . "::" . $m->name;
                $self->_generate_export_thunk( $m, $fn_name, "E_" . $node->name . "::" . $m->name );
            }
            return ( undef, 'void' );
        }

        method lower_NativeDecl($node) {
            my $lib_name  = $node->library;
            my $func_name = $node->name;
            my $sig_str   = $node->signature;
            $native_funcs{$func_name} = { library => $lib_name, signature => $sig_str };

            # Parse signature: e.g., "(String, Int)->Int"
            my ( $arg_str, $ret_type ) = $sig_str =~ /^\((.*?)\)->(.*)$/;
            $arg_str  //= '';
            $ret_type //= 'void';
            my @arg_types = length($arg_str) ? split( ',', $arg_str ) : ();
            map {s/^\s+|\s+$//g} @arg_types;
            $ret_type =~ s/^\s+|\s+$//g;

            # Reserve a global .data slot to cache the C function pointer
            my $c_ptr_offset = $data_segment->add_raw_bytes( pack( 'Q<', 0 ) );
            my $thunk_name   = "M_" . $func_name;
            $global_methods{$func_name} //= $global_method_count++;

            # Emit the thunk logic as a deferred fragment
            $self->capture_fragment(
                $thunk_name,
                sub {
                    $driver->reset_locals();
                    my @old_defers = @defer_stack;
                    @defer_stack = ();
                    $builder->emit_label($thunk_name);
                    $builder->emit( 'enter_func', 'void', [] );

                    # --- 1. CRITICAL FIX: CAPTURE REGISTERS IMMEDIATELY ---
                    # C functions (like LoadLibrary) will clobber rcx/rdx.
                    # We must save the incoming arguments to stack slots immediately.
                    my @saved_slots;
                    my $arg_idx = 0;
                    for my $t (@arg_types) {
                        my $slot    = $driver->alloc_local_slot();
                        my $raw_reg = $builder->emit( 'get_arg', 'Any', [ $arg_idx++ ] );
                        $builder->emit( 'local_store', 'void', [ $slot, $raw_reg ] );
                        push @saved_slots, $slot;
                    }

                    # Load cached C pointer
                    my $c_ptr_addr = $builder->emit( 'load_data_addr', 'ptr', [$c_ptr_offset] );
                    my $c_ptr      = $builder->emit( 'load_mem_disp',  'ptr', [ $c_ptr_addr, 0 ] );
                    my $l_has_ptr  = $builder->new_label();
                    $builder->emit_cond_br( $builder->emit( 'cmp_ne', 'Int', [ $c_ptr, 0 ] ), $l_has_ptr, $builder->new_label() );
                    $builder->emit_label( $builder->last_instruction->{false_l} );

                    # Path A: Not cached. Dynamically load the library and resolve the function.
                    my $lib_str    = $builder->emit( 'load_data_addr',             'ptr', [ $data_segment->add_string($lib_name) ] );
                    my $lib_handle = $builder->emit( 'intrinsic_load_library',     'ptr', [$lib_str] );
                    my $func_str   = $builder->emit( 'load_data_addr',             'ptr', [ $data_segment->add_string($func_name) ] );
                    my $new_c_ptr  = $builder->emit( 'intrinsic_get_proc_address', 'ptr', [ $lib_handle, $func_str ] );

                    # Cache it for next time
                    $builder->emit( 'store_mem_disp', 'void', [ $c_ptr_addr, 0, $new_c_ptr ] );
                    my $c_ptr_final_s = $driver->alloc_local_slot();
                    $builder->emit( 'local_store', 'void', [ $c_ptr_final_s, $new_c_ptr ] );
                    my $l_call = $builder->new_label();
                    $builder->emit_jump($l_call);

                    # Path B: We already have the pointer cached!
                    $builder->emit_label($l_has_ptr);
                    $builder->emit( 'local_store', 'void', [ $c_ptr_final_s, $c_ptr ] );
                    $builder->emit_jump($l_call);

                    # --- Unbox Arguments & Call C Function ---
                    $builder->emit_label($l_call);
                    my $final_c_ptr = $builder->emit( 'local_load', 'ptr', [$c_ptr_final_s] );
                    my @raw_args;
                    for my $i ( 0 .. $#arg_types ) {
                        my $t   = $arg_types[$i];
                        my $arg = $builder->emit( 'local_load', 'Any', [ $saved_slots[$i] ] );
                        if ( $t eq 'Int' || $t eq 'Bool' ) {

                            # Untag integer: arg >> 1
                            push @raw_args, $builder->emit( 'shr', 'i64', [ $arg, 1 ] );
                        }
                        elsif ( $t eq 'String' ) {

                            # C strings are just raw pointers to payload.
                            # Skip the 16-byte Brocken object header!
                            push @raw_args, $builder->emit( 'add', 'ptr', [ $arg, 16 ] );
                        }
                        else {
                            push @raw_args, $arg;    # Raw pass-through
                        }
                    }

                    # Execute the C function matching the Windows x64 ABI perfectly!
                    my $ret_val = $builder->emit( 'call_reg', 'i64', [ $final_c_ptr, @raw_args ] );

                    # --- Box Return Value ---
                    my $boxed_ret;
                    if ( $ret_type eq 'Int' || $ret_type eq 'Bool' ) {
                        $boxed_ret = $builder->emit( 'or', 'i64', [ $builder->emit( 'shl', 'i64', [ $ret_val, 1 ] ), 1 ] );
                    }
                    elsif ( $ret_type eq 'void' ) {
                        $boxed_ret = $builder->emit( 'load_data_addr', 'ptr', [$undef_ptr_offset] );
                    }
                    else {
                        # Default fallback: Treat unknown C returns as generic Ints so we don't crash
                        $boxed_ret = $builder->emit( 'or', 'i64', [ $builder->emit( 'shl', 'i64', [ $ret_val, 1 ] ), 1 ] );
                    }
                    $builder->emit( 'leave_func', 'Any', [$boxed_ret] );
                    @defer_stack = @old_defers;
                }
            );
            return ( undef, 'void' );
        }

        method register_classes($nodes) {
            my @pending  = @$nodes;
            my $progress = 1;
            while ( @pending && $progress ) {
                $progress = 0;
                my @next_pending;
                for my $node (@pending) {
                    if ( $node isa Brocken::AST::OOP::ClassDecl ) {
                        my $parent_class = undef;
                        for my $attr ( @{ $node->attributes // [] } ) {
                            if ( $attr->{name} eq 'isa' ) { $parent_class = $attr->{args}; }
                        }
                        if ( defined $parent_class && !exists $class_info{$parent_class} ) {
                            push @next_pending, $node;
                            next;
                        }
                        $progress = 1;
                        my @mn;
                        my @po;
                        my $co = 16;
                        if ( defined $parent_class ) {
                            my $p = $class_info{$parent_class};
                            push @mn, @{ $p->{method_names} };
                            push @po, @{ $p->{ptr_offsets} };
                            $co = $p->{field_end_offset};
                        }
                        my %own_methods = map { $_->name => 1 } @{ $node->methods };
                        my %own_fields;
                        for my $f ( @{ $node->fields } ) {
                            push @po, $co if $f->type =~ /^(Any|String|Array|Hash|Tuple|Fiber|Class|Undef)$/;
                            ( my $clean_name = $f->name ) =~ s/^[\$@%]//;
                            $own_fields{$clean_name} = 1;
                            $own_fields{ "set_" . $clean_name } = 1;
                            for my $mname ( $clean_name, "set_" . $clean_name ) {
                                if ( !grep { $_ eq $mname } @mn ) {
                                    push @mn, $mname;
                                    $global_methods{$mname} //= $global_method_count++;
                                }
                            }
                            $co += 8;
                        }
                        for my $m ( @{ $node->methods } ) {
                            if ( !grep { $_ eq $m->name } @mn ) {
                                push @mn, $m->name;
                                $global_methods{ $m->name } //= $global_method_count++;
                            }
                        }
                        $class_info{ $node->name } = {
                            id               => $class_id_counter++,
                            method_names     => \@mn,
                            ptr_offsets      => \@po,
                            field_end_offset => $co,
                            parent_class     => $parent_class,
                            fields           => $node->fields,
                            own_methods      => \%own_methods,
                            own_fields       => \%own_fields
                        };
                    }
                }
                @pending = @next_pending;
            }
        }

        method lower_block($stmts) {
            my ( $r, $t );
            for my $s ( grep {defined} @$stmts ) {
                ( $r, $t ) = $self->lower($s);
            }
            return ( $r, $t );
        }
    }
}
1;
