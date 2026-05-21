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
        field $global_method_count = 0;
        field $class_id_counter    = 0;
        field $anon_counter        = 0;
        field @fragments;
        field @defer_stack;
        field $defer_active_depth = 0;
        field $_skip_runtime      = 0;
        field @exported_funcs;

        # --- First-class undef pointer ---
        field $undef_ptr_offset = undef;
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

        # --- GC Runtime ---
        method inject_runtime() {
            $self->inject_runtime_gc_mark_obj();
            $self->inject_runtime_gc_sweep();
            $self->inject_runtime_gc_collect();
            $self->inject_runtime_gc_alloc();
            #
            $self->inject_runtime_init_env();
            #
            $self->inject_runtime_print_int();
            $self->inject_runtime_print_any();
            $self->inject_runtime_new_fiber();
            $self->inject_runtime_concat();
            $self->inject_runtime_to_string();
            $self->inject_runtime_unwind();

            # String Ops
            $self->inject_runtime_str_eq();
            $self->inject_runtime_str_cmp();
            $self->inject_runtime_str_slice();

            # Hash Map Runtime
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
            my $bp_slot = $driver->alloc_local_slot();
            my $my_bp   = $builder->emit( 'get_bp', 'ptr', [] );
            $builder->emit( 'local_store', 'void', [ $bp_slot, $my_bp ] );
            my $extab_ptr    = $builder->emit( 'load_iso_disp',           'ptr', [ $driver->iso_offset('exception_table') ] );
            my $text_base    = $builder->emit( 'intrinsic_get_text_base', 'ptr', [] );
            my $l_frame_loop = $builder->new_label();
            $builder->emit_label($l_frame_loop);
            my $curr_bp  = $builder->emit( 'local_load', 'ptr', [$bp_slot] );
            my $l_search = $builder->new_label();
            $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $curr_bp, 0 ] ), $builder->new_label(), $l_search );
            $builder->emit_label( $builder->last_instruction->{true_l} );
            $builder->emit( 'intrinsic_print', 'void',
                [ $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string("FATAL: Unhandled Exception\n") ] ) ] );
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
            $builder->emit( 'local_store', 'void', [ $bp_slot, $prev_bp ] );
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
            $builder->emit( 'store_mem_byte', 'void', [ $block, $builder->emit( 'add', 'i64', [ $start_line, $curr_ml ] ), 1 ] );
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
            my $mk        = $builder->emit( 'load_mem_byte', 'Int', [ $cbh, $idx ] );
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
            my $emk       = $builder->emit( 'load_mem_byte', 'Int', [ $cbh, $eidx ] );
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

        method inject_runtime_gc_collect() {
            $driver->reset_locals();
            $builder->emit_label('M_gc_collect');
            $builder->emit( 'enter_func', 'void', [] );
            $builder->emit(
                'store_iso_disp',
                'void',
                [   $driver->iso_offset('gc_cycle'),
                    $builder->emit( 'add', 'i64', [ $builder->emit( 'load_iso_disp', 'i64', [ $driver->iso_offset('gc_cycle') ] ), 1 ] )
                ]
            );
            my $bh_s = $driver->alloc_local_slot();
            $builder->emit( 'local_store', 'void', [ $bh_s, $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('heap_base') ] ) ] );
            my $l_c1 = $builder->new_label();
            my $l_c2 = $builder->new_label();
            $builder->emit_label($l_c1);
            my $cbh       = $builder->emit( 'local_load', 'ptr', [$bh_s] );
            my $l_c1_body = $builder->new_label();
            $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $cbh, 0 ] ), $l_c2, $l_c1_body );
            $builder->emit_label($l_c1_body);
            my $bm_s = $driver->alloc_local_slot();
            $builder->emit( 'local_store', 'void', [ $bm_s, 8 ] );
            my $l_cl = $builder->new_label();
            my $l_ce = $builder->new_label();
            $builder->emit_label($l_cl);
            my $bo        = $builder->emit( 'local_load', 'i64', [$bm_s] );
            my $l_cl_body = $builder->new_label();
            $builder->emit_cond_br( $builder->emit( 'cmp_ge', 'Int', [ $bo, 520 ] ), $l_ce, $l_cl_body );
            $builder->emit_label($l_cl_body);
            $builder->emit( 'store_mem_byte', 'void', [ $cbh, $bo, 0 ] );
            $builder->emit( 'local_store', 'void', [ $bm_s, $builder->emit( 'add', 'i64', [ $bo, 1 ] ) ] );
            $builder->emit_jump($l_cl);
            $builder->emit_label($l_ce);
            $builder->emit( 'local_store', 'void', [ $bh_s, $builder->emit( 'load_mem_disp', 'ptr', [ $cbh, 0 ] ) ] );
            $builder->emit_jump($l_c1);
            $builder->emit_label($l_c2);
            my $fs = $driver->alloc_local_slot();
            $builder->emit( 'local_store', 'void', [ $fs, $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('fiber_head') ] ) ] );
            my $l_fl = $builder->new_label();
            my $l_fd = $builder->new_label();
            $builder->emit_label($l_fl);
            my $fib       = $builder->emit( 'local_load', 'ptr', [$fs] );
            my $l_fl_body = $builder->new_label();
            $builder->emit_cond_br( $builder->emit( 'cmp_eq', 'Int', [ $fib, 0 ] ), $l_fd, $l_fl_body );
            $builder->emit_label($l_fl_body);
            $builder->emit( 'call_func', 'void', [ 'M_gc_mark_obj', $fib ] );
            my $cur_s = $driver->alloc_local_slot();
            $builder->emit( 'local_store', 'void', [ $cur_s, $builder->emit( 'load_mem_disp', 'ptr', [ $fib, 24 ] ) ] );
            my $l_sl = $builder->new_label();
            my $l_sd = $builder->new_label();
            $builder->emit_label($l_sl);
            my $cs        = $builder->emit( 'local_load', 'ptr', [$cur_s] );
            my $l_sl_body = $builder->new_label();
            $builder->emit_cond_br( $builder->emit( 'cmp_ge', 'Int', [ $cs, $builder->emit( 'load_mem_disp', 'ptr', [ $fib, 32 ] ) ] ),
                $l_sd, $l_sl_body );
            $builder->emit_label($l_sl_body);
            $builder->emit( 'call_func', 'void', [ 'M_gc_mark_obj', $builder->emit( 'load_mem_disp', 'ptr', [ $cs, 0 ] ) ] );
            $builder->emit( 'local_store', 'void', [ $cur_s, $builder->emit( 'add', 'ptr', [ $cs, 8 ] ) ] );
            $builder->emit_jump($l_sl);
            $builder->emit_label($l_sd);
            $builder->emit( 'local_store', 'void', [ $fs, $builder->emit( 'load_mem_disp', 'ptr', [ $fib, 48 ] ) ] );
            $builder->emit_jump($l_fl);
            $builder->emit_label($l_fd);
            my $stm = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('state_ptr') ] );

            for ( my $i = 0; $i < $state_count; $i++ ) {
                $builder->emit( 'call_func', 'void', [ 'M_gc_mark_obj', $builder->emit( 'load_mem_disp', 'ptr', [ $stm, 4096 + ( $i * 8 ) ] ) ] );
            }
            $builder->emit( 'call_func',  'void', ['M_gc_sweep'] );
            $builder->emit( 'leave_func', 'void', [0] );
        }

        method inject_runtime_gc_alloc() {
            $driver->reset_locals();
            $builder->emit_label('M_gc_alloc');
            $builder->emit( 'enter_func', 'void', [] );
            my $sz_slot = $driver->alloc_local_slot();
            my $psz     = $builder->emit( 'get_arg', 'i64', [0] );
            my $sz_raw  = $builder->emit(
                'and', 'i64',
                [   $builder->emit(
                        'add', 'i64', [ $builder->emit( 'and', 'i64', [ $psz, $builder->emit( 'constant', 'i64', [ hex("FFFFFFFFFF") ] ) ] ), 15 ]
                    ),
                    $builder->emit( 'constant', 'i64', [-8] )
                ]
            );
            $builder->emit( 'local_store', 'void', [ $sz_slot, $sz_raw ] );
            my $cyc = $builder->emit( 'and', 'i64', [ $builder->emit( 'load_iso_disp', 'i64', [ $driver->iso_offset('gc_cycle') ] ), 0xFF ] );
            my $hdr
                = $builder->emit( 'or', 'i64', [ $builder->emit( 'local_load', 'i64', [$sz_slot] ), $builder->emit( 'shl', 'i64', [ $cyc, 40 ] ) ] );
            my $fhdr_slot = $driver->alloc_local_slot();
            $builder->emit(
                'local_store',
                'void',
                [   $fhdr_slot,
                    $builder->emit(
                        'or', 'i64',
                        [ $hdr, $builder->emit( 'and', 'i64', [ $psz, $builder->emit( 'constant', 'i64', [ hex("C000000000000000") ] ) ] ) ]
                    )
                ]
            );
            my $rs      = $driver->alloc_local_slot();
            my $l_f     = $builder->new_label();
            my $l_s     = $builder->new_label();
            my $ap_slot = $driver->alloc_local_slot();
            $builder->emit( 'local_store', 'void', [ $ap_slot, $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('heap_ptr') ] ) ] );
            $builder->emit_cond_br(
                $builder->emit(
                    'cmp_lt', 'Int',
                    [   $builder->emit(
                            'add', 'ptr', [ $builder->emit( 'local_load', 'ptr', [$ap_slot] ), $builder->emit( 'local_load', 'i64', [$sz_slot] ) ]
                        ),
                        $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('heap_limit') ] )
                    ]
                ),
                $l_f, $l_s
            );
            $builder->emit_label($l_f);
            $builder->emit(
                'store_iso_disp',
                'void',
                [   $driver->iso_offset('heap_ptr'),
                    $builder->emit(
                        'add', 'ptr', [ $builder->emit( 'local_load', 'ptr', [$ap_slot] ), $builder->emit( 'local_load', 'i64', [$sz_slot] ) ]
                    )
                ]
            );
            $builder->emit( 'store_mem_disp', 'void',
                [ $builder->emit( 'local_load', 'ptr', [$ap_slot] ), 0, $builder->emit( 'local_load', 'i64', [$fhdr_slot] ) ] );
            $builder->emit( 'local_store', 'void', [ $rs, $builder->emit( 'local_load', 'ptr', [$ap_slot] ) ] );
            my $l_z = $builder->new_label();
            $builder->emit_jump($l_z);
            $builder->emit_label($l_s);
            $builder->emit( 'call_func',   'void', ['M_gc_collect'] );
            $builder->emit( 'local_store', 'void', [ $ap_slot, $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('heap_ptr') ] ) ] );
            my $l_f2 = $builder->new_label();
            my $l_s2 = $builder->new_label();
            $builder->emit_cond_br(
                $builder->emit(
                    'cmp_lt', 'Int',
                    [   $builder->emit(
                            'add', 'ptr', [ $builder->emit( 'local_load', 'ptr', [$ap_slot] ), $builder->emit( 'local_load', 'i64', [$sz_slot] ) ]
                        ),
                        $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('heap_limit') ] )
                    ]
                ),
                $l_f2, $l_s2
            );
            $builder->emit_label($l_f2);
            $builder->emit(
                'store_iso_disp',
                'void',
                [   $driver->iso_offset('heap_ptr'),
                    $builder->emit(
                        'add', 'ptr', [ $builder->emit( 'local_load', 'ptr', [$ap_slot] ), $builder->emit( 'local_load', 'i64', [$sz_slot] ) ]
                    )
                ]
            );
            $builder->emit( 'store_mem_disp', 'void',
                [ $builder->emit( 'local_load', 'ptr', [$ap_slot] ), 0, $builder->emit( 'local_load', 'i64', [$fhdr_slot] ) ] );
            $builder->emit( 'local_store', 'void', [ $rs, $builder->emit( 'local_load', 'ptr', [$ap_slot] ) ] );
            $builder->emit_jump($l_z);
            $builder->emit_label($l_s2);
            my $raw_slot = $driver->alloc_local_slot();
            $builder->emit( 'local_store', 'void', [ $raw_slot, $builder->emit( 'intrinsic_alloc', 'ptr', [131072] ) ] );
            my $fr_slot = $driver->alloc_local_slot();
            $builder->emit(
                'local_store',
                'void',
                [   $fr_slot,
                    $builder->emit(
                        'and', 'i64',
                        [   $builder->emit( 'add',      'ptr', [ $builder->emit( 'local_load', 'ptr', [$raw_slot] ), 65535 ] ),
                            $builder->emit( 'constant', 'i64', [ hex("FFFFFFFFFFFF0000") ] )
                        ]
                    )
                ]
            );
            $builder->emit(
                'store_mem_disp',
                'void',
                [   $builder->emit( 'local_load', 'ptr', [$fr_slot] ),
                    0, $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('heap_base') ] )
                ]
            );
            $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('heap_base'), $builder->emit( 'local_load', 'ptr', [$fr_slot] ) ] );

            # --- Heap Block Signature ---
            my $fr = $builder->emit( 'local_load', 'ptr', [$fr_slot] );
            $builder->emit( 'store_mem_disp', 'void', [ $fr, 8, $builder->emit( 'constant', 'i64', [0x424b4e4845415036] ) ] );
            my $mz = $driver->alloc_local_slot();
            $builder->emit( 'local_store', 'void', [ $mz, $builder->emit( 'local_load', 'ptr', [$fr_slot] ) ] );
            my $l_mzl = $builder->new_label();
            my $l_mze = $builder->new_label();
            $builder->emit_label($l_mzl);
            my $cmz        = $builder->emit( 'local_load', 'ptr', [$mz] );
            my $l_mzl_body = $builder->new_label();
            $builder->emit_cond_br(
                $builder->emit(
                    'cmp_lt', 'Int', [ $cmz, $builder->emit( 'add', 'ptr', [ $builder->emit( 'local_load', 'ptr', [$fr_slot] ), 1024 ] ) ]
                ),
                $l_mzl_body,
                $l_mze
            );
            $builder->emit_label($l_mzl_body);
            $builder->emit( 'store_mem_disp', 'void', [ $cmz, 0, 0 ] );
            $builder->emit( 'local_store', 'void', [ $mz, $builder->emit( 'add', 'ptr', [ $cmz, 8 ] ) ] );
            $builder->emit_jump($l_mzl);
            $builder->emit_label($l_mze);
            my $st_slot = $driver->alloc_local_slot();
            $builder->emit( 'local_store', 'void',
                [ $st_slot, $builder->emit( 'add', 'ptr', [ $builder->emit( 'local_load', 'ptr', [$fr_slot] ), 1024 ] ) ] );
            $builder->emit( 'store_mem_disp', 'void',
                [ $builder->emit( 'local_load', 'ptr', [$st_slot] ), 0, $builder->emit( 'local_load', 'i64', [$fhdr_slot] ) ] );
            $builder->emit(
                'store_iso_disp',
                'void',
                [   $driver->iso_offset('heap_ptr'),
                    $builder->emit(
                        'add', 'ptr', [ $builder->emit( 'local_load', 'ptr', [$st_slot] ), $builder->emit( 'local_load', 'i64', [$sz_slot] ) ]
                    )
                ]
            );
            $builder->emit( 'store_iso_disp', 'void',
                [ $driver->iso_offset('heap_limit'), $builder->emit( 'add', 'ptr', [ $builder->emit( 'local_load', 'ptr', [$fr_slot] ), 65536 ] ) ] );
            $builder->emit( 'local_store', 'void', [ $rs, $builder->emit( 'local_load', 'ptr', [$st_slot] ) ] );
            $builder->emit_label($l_z);
            my $res_slot = $driver->alloc_local_slot();
            $builder->emit( 'local_store', 'void', [ $res_slot, $builder->emit( 'local_load', 'ptr', [$rs] ) ] );
            my $obj_slot = $driver->alloc_local_slot();
            $builder->emit( 'local_store', 'void',
                [ $obj_slot, $builder->emit( 'add', 'ptr', [ $builder->emit( 'local_load', 'ptr', [$res_slot] ), 8 ] ) ] );
            my $zp = $driver->alloc_local_slot();
            $builder->emit( 'local_store', 'void', [ $zp, $builder->emit( 'local_load', 'ptr', [$obj_slot] ) ] );
            my $l_zl = $builder->new_label();
            my $l_ze = $builder->new_label();
            $builder->emit_label($l_zl);
            my $l_zl_body = $builder->new_label();
            $builder->emit_cond_br(
                $builder->emit(
                    'cmp_lt', 'Int',
                    [   $builder->emit( 'local_load', 'ptr', [$zp] ),
                        $builder->emit(
                            'add', 'ptr', [ $builder->emit( 'local_load', 'ptr', [$res_slot] ), $builder->emit( 'local_load', 'i64', [$sz_slot] ) ]
                        )
                    ]
                ),
                $l_zl_body,
                $l_ze
            );
            $builder->emit_label($l_zl_body);
            $builder->emit( 'store_mem_disp', 'void', [ $builder->emit( 'local_load', 'ptr', [$zp] ), 0, 0 ] );
            $builder->emit( 'local_store', 'void', [ $zp, $builder->emit( 'add', 'ptr', [ $builder->emit( 'local_load', 'ptr', [$zp] ), 8 ] ) ] );
            $builder->emit_jump($l_zl);
            $builder->emit_label($l_ze);
            $builder->emit( 'leave_func', 'void', [ $builder->emit( 'local_load', 'ptr', [$obj_slot] ) ] );
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
                                [   $builder->emit( 'add',      'i64', [ $builder->emit( 'local_load', 'i64', [$tl_slot] ), 24 ] ),
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
            $builder->emit_label($l_f1);
            $builder->emit( 'leave_func', 'void', [ $builder->emit( 'local_load', 'i64', [$v_slot] ) ] );
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
                        [   $builder->emit( 'add',      'i64', [ $builder->emit( 'local_load', 'i64', [$sl_slot] ), 24 ] ),
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
            $builder->emit( 'leave_func', 'void', [ $builder->emit( 'local_load', 'ptr', [$ns_p_slot] ) ] );
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
            my $ms = $builder->emit( 'intrinsic_alloc', 'ptr', [1048576] );
            $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('mark_stack_base'),  $ms ] );
            $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('mark_stack_ptr'),   $ms ] );
            $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('mark_stack_limit'), $builder->emit( 'add', 'ptr', [ $ms, 1048576 ] ) ] );
            my $raw_heap = $builder->emit( 'intrinsic_alloc', 'ptr', [131072] );
            my $mask     = $builder->emit( 'constant',        'i64', [ hex("FFFFFFFFFFFF0000") ] );
            my $hp       = $builder->emit( 'and',             'i64', [ $builder->emit( 'add', 'ptr', [ $raw_heap, 65535 ] ), $mask ] );
            $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('heap_base'),  $hp ] );
            $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('heap_min'),   $hp ] );
            $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('heap_max'),   $builder->emit( 'add',      'ptr', [ $hp, 65536 ] ) ] );
            $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('heap_ptr'),   $builder->emit( 'add',      'ptr', [ $hp, 1024 ] ) ] );
            $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('heap_limit'), $builder->emit( 'add',      'ptr', [ $hp, 65536 ] ) ] );
            $builder->emit( 'store_iso_disp', 'void', [ $driver->iso_offset('gc_cycle'),   $builder->emit( 'constant', 'i64', [1] ) ] );

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
                # Tag: (0 items << 2) | 1 = 1
                my $argv_arr = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', $builder->emit( 'constant', 'i64', [8] ) ] );
                $builder->emit( 'store_mem_disp', 'void', [ $argv_arr, 0, $builder->emit( 'constant', 'i64', [1] ) ] );
                $builder->emit( 'store_iso_disp', 'void', [ 208, $argv_arr ] );

                # 6. Instantiate $_ as undef
                my $undef_ptr = $builder->emit( 'load_data_addr', 'ptr', [$undef_ptr_offset] );
                $builder->emit( 'store_iso_disp', 'void', [ 216, $undef_ptr ] );
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

            # Allocate String: size = 16 (Header) + len + 8 (padding boundary)
            my $sz  = $builder->emit( 'add', 'i64', [ $len, 24 ] );
            my $str = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', $sz ] );
            $builder->emit( 'shadow_push', 'void', [$str] );

            # Tag: Leaf/String Bit Set | Byte Length
            my $tag = $builder->emit( 'or', 'i64', [ $len, $builder->emit( 'constant', 'i64', [ hex("C000000000000000") ] ) ] );
            $builder->emit( 'store_mem_disp', 'void', [ $str, -8, $tag ] );

            # Store metadata
            $builder->emit( 'store_mem_disp', 'void', [ $str, 0, $len ] );    # Byte len
            $builder->emit( 'store_mem_disp', 'void', [ $str, 8, $len ] );    # Char len (assume ASCII for env)

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
            $builder->emit_label($l_block_loop);
            my $block  = $builder->emit( 'local_load', 'ptr', [$block_s] );
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
            $builder->emit( 'local_store', 'void',
                [ $cursor_s, $builder->emit( 'add', 'i64', [ $builder->emit( 'add', 'i64', [ $cursor, $total_len ] ), 1 ] ) ] );
            $builder->emit_jump($l_block_loop);
            $builder->emit_label($l_block_done);
            $builder->emit( 'intrinsic_free_env_block', 'void', [$block] );
            $builder->emit( 'shadow_pop',               'void', [] );         # pop env_hash
            $builder->emit( 'leave_func',               'void', [] );
        }

        # --- AST Lowering Dispatcher ---
        method lower($node) {
            return ( undef, 'void' ) unless defined $node;
            my $nt = ref($node);
            $nt =~ s/.*:://;
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
            $builder->emit_jump('L_MAIN_START');
            $self->inject_runtime();
            $self->_emit_runtime_init_sub();
            $self->register_classes($nodes);
            my @main_statements;
            for my $n (@$nodes) {
                if ( $n isa Brocken::AST::OOP::Method || $n isa Brocken::AST::OOP::ClassDecl || $n isa Brocken::AST::NativeDecl ) {
                    $self->lower($n);
                }
                else { push @main_statements, $n; }
            }
            $builder->emit_label('L_MAIN_START');
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
                    my $m_addr = $builder->emit( 'load_func_addr', 'ptr', ["M_${cn}::$mn"] );
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
            if ( $node->name eq 'keys' ) {
                return ( $builder->emit( 'call_func', 'ptr', [ 'M_hash_keys', ( $self->lower( $node->args->[0] ) )[0] ] ), 'Array' );
            }
            if ( $node->name eq 'values' ) {
                return ( $builder->emit( 'call_func', 'ptr', [ 'M_hash_values', ( $self->lower( $node->args->[0] ) )[0] ] ), 'Array' );
            }
            my @as        = map { ( $self->lower($_) )[0] } @{ $node->args };
            my $sp_backup = $builder->emit( 'shadow_get', 'ptr', [] );
            my $res       = $builder->emit( 'call_func',  'i64', [ "M_" . $node->name, @as ] );
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
            else { $builder->emit( 'leave_func', 'void', [$rv] ); }
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
            my @as = map { ( $self->lower($_) )[0] } @{ $node->args };
            if ( $ot eq 'Fiber' && $mn eq 'switch' ) { return ( $builder->emit( 'call_func', 'Any', [ 'M_fiber_switch', $or, @as ] ), 'Any' ); }
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
            $builder->emit_label($l_is_arr);
            my $raw_idx = $builder->emit( 'shr', 'i64', [ $idx_reg, 1 ] );
            my $addr    = $builder->emit( 'add', 'ptr',
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
        method lower_Use($node)  { return $self->lower_Require($node); }

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
            my $off = 16;
            for my $f ( @{ $node->fields } ) { $off += 8 }
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
                for my $field ( @{ $node->fields } ) { $current_scope->define( $field->name, 'Any', 0, undef, -$fo ); $fo += 8 }

                for my $p ( @{ $m->params } ) {
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
            $native_funcs{ $node->name } = { library => $node->library, signature => $node->signature };
            return ( undef, 'void' );
        }

        method register_classes($nodes) {
            for my $node (@$nodes) {
                if ( $node isa Brocken::AST::OOP::ClassDecl ) {
                    my @mn;
                    my @po;
                    my $co = 16;
                    for my $m ( @{ $node->methods } ) { push @mn, $m->name; $global_methods{ $m->name } //= $global_method_count++ }
                    for my $f ( @{ $node->fields } ) {
                        push @po, $co if $f->type =~ /^(Any|String|Array|Hash|Tuple|Fiber|Class|Undef)$/;
                        ( my $clean_name = $f->name ) =~ s/^[\$@%]//;
                        push @mn, $clean_name;
                        $global_methods{$clean_name} //= $global_method_count++;
                        push @mn, "set_" . $clean_name;
                        $global_methods{ "set_" . $clean_name } //= $global_method_count++;
                        $co += 8;
                    }
                    $class_info{ $node->name } = { id => $class_id_counter++, method_names => \@mn, ptr_offsets => \@po };
                }
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
