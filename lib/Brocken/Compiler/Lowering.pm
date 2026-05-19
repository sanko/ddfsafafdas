package Brocken::Compiler::Lowering {
    use v5.40;
    use utf8;
    use feature 'class';
    no warnings 'portable', 'experimental::class';
    use Brocken::IR;
    use Brocken::AST;
    use Brocken::Type;
    use Brocken::JIT;

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
        field $anon_counter = 0;
        field @fragments;
        field @defer_stack;
        field $defer_active_depth = 0;
        field $_skip_runtime      = 0;
        field @exported_funcs;

        method class_info () { return %class_info }
        method exported_funcs () { return \@exported_funcs; }
        method skip_runtime           { $_skip_runtime }
        method set_skip_runtime($val) { $_skip_runtime = $val }

        # --- Exact Write Barrier ---
        method _emit_write_barrier($base, $offset, $val) {
            my $l_next = $builder->new_label();
            my $old = $builder->emit('load_mem_disp', 'ptr', [$base, $offset]);

            my $l_old_not_null = $builder->new_label();
            $builder->emit_cond_br($builder->emit('cmp_eq', 'Int', [$old, 0]), $l_next, $l_old_not_null);
            $builder->emit_label($l_old_not_null);

            my $is_smi_old = $builder->emit('and', 'i64', [$old, 1]);
            my $l_old_not_smi = $builder->new_label();
            $builder->emit_cond_br($builder->emit('cmp_ne', 'Int', [$is_smi_old, 0]), $l_next, $l_old_not_smi);
            $builder->emit_label($l_old_not_smi);
            {
                my $hdr = $builder->emit('load_mem_disp', 'i64', [$old, -8]);
                my $shared = $builder->emit('and', 'i64', [$builder->emit('shr','i64',[$hdr, 62]), 1]);
                my $l_local = $builder->new_label();
                my $l_done = $builder->new_label();

                my $l_atomic = $builder->new_label();
                $builder->emit_cond_br($builder->emit('cmp_eq', 'Int', [$shared, 0]), $l_local, $l_atomic);

                $builder->emit_label($l_atomic);
                $builder->emit('atomic_dec_ref', 'void', [$old]);
                $builder->emit_jump($l_done);

                $builder->emit_label($l_local);
                $builder->emit('local_dec_ref', 'void', [$old]);
                $builder->emit_label($l_done);
            }
            $builder->emit_label($l_next);

            # Store NEW
            $builder->emit('store_mem_disp', 'void', [$base, $offset, $val]);

            # IncRef NEW
            my $l_end = $builder->new_label();
            my $l_new_not_null = $builder->new_label();
            $builder->emit_cond_br($builder->emit('cmp_eq', 'Int', [$val, 0]), $l_end, $l_new_not_null);
            $builder->emit_label($l_new_not_null);

            my $is_smi_new = $builder->emit('and', 'i64', [$val, 1]);
            my $l_new_not_smi = $builder->new_label();
            $builder->emit_cond_br($builder->emit('cmp_ne', 'Int', [$is_smi_new, 0]), $l_end, $l_new_not_smi);
            $builder->emit_label($l_new_not_smi);
            {
                my $hdr = $builder->emit('load_mem_disp', 'i64', [$val, -8]);
                my $shared = $builder->emit('and', 'i64', [$builder->emit('shr','i64',[$hdr, 62]), 1]);
                my $l_local = $builder->new_label();
                my $l_done = $builder->new_label();

                my $l_atomic = $builder->new_label();
                $builder->emit_cond_br($builder->emit('cmp_eq', 'Int', [$shared, 0]), $l_local, $l_atomic);

                $builder->emit_label($l_atomic);
                $builder->emit('atomic_inc_ref', 'void', [$val]);
                $builder->emit_jump($l_done);

                $builder->emit_label($l_local);
                $builder->emit('local_inc_ref', 'void', [$val]);
                $builder->emit_label($l_done);
            }
            $builder->emit_label($l_end);
        }

        method _emit_bool_test($reg) {
            return $builder->emit('shr', 'i64', [$reg, 1]);
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
                $cond_reg = $builder->emit( 'cmp_ne', 'Int', [ $l_reg, 0 ] );
            } else {
                $cond_reg = $self->_emit_bool_test($l_reg);
            }

            my $l_false = $builder->new_label();
            my $l_true  = $builder->new_label();

            if ( $op eq '&&' ) {
                $builder->emit_cond_br( $cond_reg, $l_true, $l_end );
                $builder->emit_label($l_true);
            } else {
                $builder->emit_cond_br( $cond_reg, $l_end, $l_false );
                $builder->emit_label($l_false);
            }

            my ( $r_reg, $r_typ ) = $self->lower( $node->right );
            $builder->emit( 'local_store', 'void', [ $res_slot, $r_reg ] );
            $builder->emit_label($l_end);
            return ( $builder->emit( 'local_load', 'Any', [$res_slot] ), 'Any' );
        }

        method _generate_export_thunk($node) {
            my $internal_name = 'M_' . $node->name;
            my $export_name   = 'E_' . $node->name;
            $builder->emit_label($export_name);
            $builder->emit( 'enter_func', 'void', [] );

            $builder->emit( 'set_isolate_ctx', 'void',
                [ $builder->emit( 'load_mem_disp', 'i64', [ $builder->emit( 'load_data_addr', 'ptr', [ $driver->global_iso_offset ] ), 0 ] ) ] );
            my @boxed_args;
            my $arg_idx = 0;

            for my $p ( @{ $node->params } ) {
                my $param_type = $p->{type};
                my $ir_type = 'i64';
                if ( $param_type eq 'Float' || $param_type eq 'double' ) {
                    $ir_type = 'double';
                }
                my $raw_arg = $builder->emit( 'get_arg', $ir_type, [ $arg_idx++ ] );
                if ( $param_type eq 'Int' || $param_type =~ /^Int\d+$/ ) {
                    my $shifted = $builder->emit( 'shl', 'i64', [ $raw_arg, 1 ] );
                    my $boxed   = $builder->emit( 'or',  'i64', [ $shifted, 1 ] );
                    push @boxed_args, $boxed;
                } elsif ( $param_type eq 'Float' || $param_type eq 'double' ) {
                    push @boxed_args, $raw_arg;
                } else {
                    push @boxed_args, $raw_arg;
                }
            }

            my $has_float = grep { $_->{type} eq 'Float' || $_->{type} eq 'double' } @{ $node->params };
            my $ret_type  = $has_float ? 'double' : 'i64';
            my $result    = $builder->emit( 'call_func', $ret_type, [ $internal_name, @boxed_args ] );

            if ($has_float) {
                $builder->emit( 'leave_func', 'double', [$result] );
            } else {
                $builder->emit( 'leave_func', 'i64', [$result] );
            }
        }

        # --- GC Runtime ---

        method inject_runtime() {
            $self->inject_runtime_gc_mark_obj();
            $self->inject_runtime_gc_sweep();
            $self->inject_runtime_gc_collect();
            $self->inject_runtime_gc_alloc();
            $self->inject_runtime_print_int();
            $self->inject_runtime_print_any();
            $self->inject_runtime_new_fiber();
            $self->inject_runtime_concat();
            $self->inject_runtime_to_string();
            $self->inject_runtime_unwind();
        }


    method inject_runtime_unwind() {
        $driver->reset_locals();
        $builder->emit_label('M_unwind');
        $builder->emit('enter_func', 'void', []);

        my $bp_slot = $driver->alloc_local_slot();
        # Start walking from M_unwind's caller's frame
        $builder->emit('local_store', 'void', [$bp_slot, $builder->emit('get_bp', 'ptr', [])]);

        my $extab_ptr = $builder->emit('load_iso_disp', 'ptr', [$driver->iso_offset('exception_table')]);
        my $text_base = $builder->emit('intrinsic_get_text_base', 'ptr', []);

        my $l_frame_loop = $builder->new_label();
        $builder->emit_label($l_frame_loop);

        my $curr_bp = $builder->emit('local_load', 'ptr', [$bp_slot]);

        my $l_search = $builder->new_label();
        $builder->emit_cond_br($builder->emit('cmp_eq', 'Int', [$curr_bp, 0]), $builder->new_label(), $l_search);
        $builder->emit_label($builder->last_instruction->{true_l});
        $builder->emit('intrinsic_print', 'void', [$builder->emit('load_data_addr', 'ptr', [$data_segment->add_string("FATAL: Unhandled Exception\n")])]);
        $builder->emit('intrinsic_exit', 'void', [$builder->emit('constant', 'i64', [255])]);

        $builder->emit_label($l_search);
        my $rip = $builder->emit('load_mem_disp', 'ptr', [$curr_bp, 8]);
        my $prev_bp = $builder->emit('load_mem_disp', 'ptr', [$curr_bp, 0]);
        my $rva = $builder->emit('sub', 'i64', [$builder->emit('sub', 'i64', [$rip, $text_base]), 1]);

        my $num_funcs = $builder->emit('load_mem_disp', 'i64', [$extab_ptr, 0]);
        my $fi_s = $driver->alloc_local_slot(); $builder->emit('local_store', 'void', [$fi_s, 0]);
        my $f_ptr_s = $driver->alloc_local_slot(); $builder->emit('local_store', 'void', [$f_ptr_s, $builder->emit('add','ptr',[$extab_ptr, 8])]);

        my $l_f_loop = $builder->new_label();
        $builder->emit_label($l_f_loop);
        my $fi = $builder->emit('local_load', 'i64', [$fi_s]);

        my $l_f_done = $builder->new_label();
        $builder->emit_cond_br($builder->emit('cmp_ge', 'Int', [$fi, $num_funcs]), $l_f_done, $builder->new_label());
        $builder->emit_label($builder->last_instruction->{false_l});

        my $f_ptr = $builder->emit('local_load', 'ptr', [$f_ptr_s]);
        my $f_start = $builder->emit('load_mem_disp', 'i64', [$f_ptr, 0]);
        my $f_end   = $builder->emit('load_mem_disp', 'i64', [$f_ptr, 8]);
        my $num_tries = $builder->emit('load_mem_disp', 'i64', [$f_ptr, 16]);

        my $l_check_tries = $builder->new_label();
        my $l_f_inc = $builder->new_label();
        my $in_f = $builder->emit('and', 'i64', [$builder->emit('cmp_ge', 'Int', [$rva, $f_start]), $builder->emit('cmp_lt', 'Int', [$rva, $f_end])]);
        $builder->emit_cond_br($in_f, $l_check_tries, $l_f_inc);

        $builder->emit_label($l_check_tries);
        my $ti_s = $driver->alloc_local_slot(); $builder->emit('local_store', 'void', [$ti_s, 0]);
        my $t_ptr_s = $driver->alloc_local_slot(); $builder->emit('local_store', 'void', [$t_ptr_s, $builder->emit('add','ptr',[$f_ptr, 24])]);

        my $l_t_loop = $builder->new_label();
        $builder->emit_label($l_t_loop);
        my $ti = $builder->emit('local_load', 'i64', [$ti_s]);
        $builder->emit_cond_br($builder->emit('cmp_ge', 'Int', [$ti, $num_tries]), $l_f_done, $builder->new_label());
        $builder->emit_label($builder->last_instruction->{false_l});

        my $t_ptr = $builder->emit('local_load', 'ptr', [$t_ptr_s]);
        my $t_start = $builder->emit('load_mem_disp', 'i64', [$t_ptr, 0]);
        my $t_end   = $builder->emit('load_mem_disp', 'i64', [$t_ptr, 8]);

        my $l_t_match = $builder->new_label();
        my $l_t_inc = $builder->new_label();
        my $in_t = $builder->emit('and', 'i64', [$builder->emit('cmp_ge', 'Int', [$rva, $t_start]), $builder->emit('cmp_lt', 'Int', [$rva, $t_end])]);
        $builder->emit_cond_br($in_t, $l_t_match, $l_t_inc);

        $builder->emit_label($l_t_match);
        my $catch_pc = $builder->emit('load_mem_disp', 'i64', [$t_ptr, 16]);
        $builder->emit('intrinsic_restore_context', 'void', [$curr_bp, $builder->emit('add', 'ptr', [$text_base, $catch_pc])]);

        $builder->emit_label($l_t_inc);
        $builder->emit('local_store', 'void', [$ti_s, $builder->emit('add', 'i64', [$ti, 1])]);
        $builder->emit('local_store', 'void', [$t_ptr_s, $builder->emit('add', 'ptr', [$t_ptr, 32])]);
        $builder->emit_jump($l_t_loop);

        $builder->emit_label($l_f_inc);
        $builder->emit('local_store', 'void', [$fi_s, $builder->emit('add', 'i64', [$fi, 1])]);
        my $f_skip = $builder->emit('add', 'i64', [24, $builder->emit('mul', 'i64', [$num_tries, 32])]);
        $builder->emit('local_store', 'void', [$f_ptr_s, $builder->emit('add', 'ptr', [$f_ptr, $f_skip])]);
        $builder->emit_jump($l_f_loop);

        $builder->emit_label($l_f_done);
        $builder->emit('local_store', 'void', [$bp_slot, $prev_bp]);
        $builder->emit_jump($l_frame_loop);

        $builder->emit('leave_func', 'void', []);
    }

        method inject_runtime_gc_mark_obj() {
            $driver->reset_locals();
            $builder->emit_label('M_gc_mark_obj');
            $builder->emit('enter_func', 'void', []);

            my $root_slot = $driver->alloc_local_slot();
            $builder->emit('local_store', 'void', [$root_slot, $builder->emit('get_arg', 'ptr', [0])]);

            my $ms_ptr = $builder->emit('load_iso_disp', 'ptr', [112]);
            $builder->emit('store_mem_disp', 'void', [$ms_ptr, 0, $builder->emit('local_load','ptr',[$root_slot])]);
            $builder->emit('store_iso_disp', 'void', [112, $builder->emit('add','ptr',[$ms_ptr, 8])]);

            my $l_mark_start = $builder->new_label();
            my $l_mark_done  = $builder->new_label();
            $builder->emit_label($l_mark_start);

            my $curr_ms = $builder->emit('load_iso_disp', 'ptr', [112]);
            my $ms_base = $builder->emit('load_iso_disp', 'ptr', [104]);
            my $l_stack_not_empty = $builder->new_label();
            $builder->emit_cond_br($builder->emit('cmp_le', 'Int', [$curr_ms, $ms_base]), $l_mark_done, $l_stack_not_empty);
            $builder->emit_label($l_stack_not_empty);

            my $pop_ptr = $builder->emit('sub', 'ptr', [$curr_ms, 8]);
            $builder->emit('local_store', 'void', [$root_slot, $builder->emit('load_mem_disp', 'ptr', [$pop_ptr, 0])]);
            $builder->emit('store_iso_disp', 'void', [112, $pop_ptr]);

            my $l_next = $l_mark_start;
            my $l_not_null = $builder->new_label();
            $builder->emit_cond_br($builder->emit('cmp_eq', 'Int', [$builder->emit('local_load','ptr',[$root_slot]), 0]), $l_next, $l_not_null);
            $builder->emit_label($l_not_null);

            my $l_not_smi = $builder->new_label();
            $builder->emit_cond_br($builder->emit('and', 'i64', [$builder->emit('local_load','ptr',[$root_slot]), 1]), $l_next, $l_not_smi);
            $builder->emit_label($l_not_smi);

            my $hdr_slot = $driver->alloc_local_slot();
            $builder->emit('local_store', 'i64', [$hdr_slot, $builder->emit('load_mem_disp', 'i64', [$builder->emit('local_load','ptr',[$root_slot]), -8])]);

            my $cyc = $builder->emit('load_iso_disp', 'i64', [80]);
            my $obj_cyc = $builder->emit('and', 'i64', [$builder->emit('shr','i64',[$builder->emit('local_load','i64',[$hdr_slot]), 40]), 0xFF]);

            my $l_not_marked = $builder->new_label();
            $builder->emit_cond_br($builder->emit('cmp_eq', 'Int', [$obj_cyc, $cyc]), $l_next, $l_not_marked);
            $builder->emit_label($l_not_marked);

            my $block = $builder->emit('and', 'i64', [$builder->emit('local_load','ptr',[$root_slot]), $builder->emit('constant', 'i64', [hex("FFFFFFFFFFFF0000")])]);
            my $off = $builder->emit('sub', 'i64', [$builder->emit('sub','i64',[$builder->emit('local_load','ptr',[$root_slot]), 8]), $block]);
            my $start_line = $builder->emit('shr', 'i64', [$off, 7]);
            my $obj_sz = $builder->emit('and', 'i64', [$builder->emit('local_load','i64',[$hdr_slot]), $builder->emit('constant', 'i64', [hex("FFFFFFFFFF")])]);

            my $off_mod_128 = $builder->emit('and','i64',[$off,127]);
            my $span = $builder->emit('add','i64',[$obj_sz, $off_mod_128]);
            my $num_lines = $builder->emit('div', 'i64', [$builder->emit('add','i64',[$span, 127]), 128]);

            my $ml_i = $driver->alloc_local_slot();
            $builder->emit('local_store','void',[$ml_i, 0]);
            my $l_ml = $builder->new_label(); my $l_md = $builder->new_label();
            $builder->emit_label($l_ml);

            my $curr_ml = $builder->emit('local_load','i64',[$ml_i]);
            my $l_ml_body = $builder->new_label();
            $builder->emit_cond_br($builder->emit('cmp_lt','Int',[$curr_ml, $num_lines]), $l_ml_body, $l_md);
            $builder->emit_label($l_ml_body);

            $builder->emit('store_mem_byte', 'void', [$block, $builder->emit('add','i64',[$start_line, $curr_ml]), 1]);
            $builder->emit('local_store','void',[$ml_i, $builder->emit('add','i64',[$curr_ml, 1])]);
            $builder->emit_jump($l_ml);
            $builder->emit_label($l_md);

            my $clean_hdr = $builder->emit('and','i64',[$builder->emit('local_load','i64',[$hdr_slot]), $builder->emit('constant', 'i64', [~(0xFF << 40)])]);
            my $marked_hdr = $builder->emit('or','i64',[$clean_hdr, $builder->emit('shl','i64',[$cyc, 40])]);
            $builder->emit('store_mem_disp', 'void', [$builder->emit('local_load','ptr',[$root_slot]), -8, $marked_hdr]);

            my $l_not_leaf = $builder->new_label();
            $builder->emit_cond_br($builder->emit('cmp_eq','Int',[$builder->emit('shr','i64',[$builder->emit('local_load','i64',[$hdr_slot]), 62]), 3]), $l_next, $l_not_leaf);
            $builder->emit_label($l_not_leaf);

            my $first = $builder->emit('load_mem_disp', 'i64', [$builder->emit('local_load','ptr',[$root_slot]), 0]);
            my $l_is_obj = $builder->new_label();
            my $l_is_array = $builder->new_label();
            $builder->emit_cond_br($builder->emit('and','i64',[$first, 1]), $l_is_array, $l_is_obj);

            $builder->emit_label($l_is_array);
            my $count = $builder->emit('shr', 'i64', [$first, 1]);
            my $ai_s = $driver->alloc_local_slot();
            $builder->emit('local_store','void',[$ai_s,0]);
            my $l_al = $builder->new_label();
            $builder->emit_label($l_al);

            my $ai = $builder->emit('local_load','i64',[$ai_s]);
            my $l_al_body = $builder->new_label();
            $builder->emit_cond_br($builder->emit('cmp_ge','Int',[$ai, $count]), $l_mark_start, $l_al_body);
            $builder->emit_label($l_al_body);

            my $el_ptr = $builder->emit('add','ptr',[$builder->emit('local_load','ptr',[$root_slot]), $builder->emit('add','i64',[$builder->emit('mul','i64',[$ai, 8]), 8])]);
            my $el = $builder->emit('load_mem_disp', 'ptr', [$el_ptr, 0]);
            my $p_ptr = $builder->emit('load_iso_disp', 'ptr', [112]);
            $builder->emit('store_mem_disp', 'void', [$p_ptr, 0, $el]);
            $builder->emit('store_iso_disp', 'void', [112, $builder->emit('add','ptr',[$p_ptr, 8])]);
            $builder->emit('local_store','void',[$ai_s, $builder->emit('add','i64',[$ai, 1])]);
            $builder->emit_jump($l_al);

            $builder->emit_label($l_is_obj);
            my $p_ct = $builder->emit('load_mem_disp', 'i64', [$first, -8]);
            my $pi_s = $driver->alloc_local_slot();
            $builder->emit('local_store','void',[$pi_s, 0]);
            my $l_ol = $builder->new_label();
            $builder->emit_label($l_ol);

            my $pi = $builder->emit('local_load','i64',[$pi_s]);
            my $l_ol_body = $builder->new_label();
            $builder->emit_cond_br($builder->emit('cmp_ge','Int',[$pi, $p_ct]), $l_mark_start, $l_ol_body);
            $builder->emit_label($l_ol_body);

            my $voff_ptr = $builder->emit('sub','ptr',[$first, $builder->emit('add','i64',[$builder->emit('mul','i64',[$pi, 8]), 16])]);
            my $voff = $builder->emit('load_mem_disp', 'i64', [$voff_ptr, 0]);
            my $ch = $builder->emit('load_mem_disp', 'ptr', [$builder->emit('add','ptr',[$builder->emit('local_load','ptr',[$root_slot]), $voff]), 0]);
            my $o_ptr = $builder->emit('load_iso_disp', 'ptr', [112]);
            $builder->emit('store_mem_disp', 'void', [$o_ptr, 0, $ch]);
            $builder->emit('store_iso_disp', 'void', [112, $builder->emit('add','ptr',[$o_ptr, 8])]);
            $builder->emit('local_store','void',[$pi_s, $builder->emit('add','i64',[$pi, 1])]);
            $builder->emit_jump($l_ol);

            $builder->emit_label($l_mark_done);
            $builder->emit('leave_func', 'void', [0]);
        }

        method inject_runtime_gc_sweep() {
            $driver->reset_locals();
            $builder->emit_label('M_gc_sweep');
            $builder->emit('enter_func', 'void', []);
            my $bh_s = $driver->alloc_local_slot();
            $builder->emit('local_store', 'void', [$bh_s, $builder->emit('load_iso_disp', 'ptr', [40])]);
            my $l_bl = $builder->new_label();
            my $l_bd = $builder->new_label();
            $builder->emit_label($l_bl);

            my $cbh = $builder->emit('local_load', 'ptr', [$bh_s]);
            my $l_bl_body = $builder->new_label();
            $builder->emit_cond_br($builder->emit('cmp_eq','Int',[$cbh, 0]), $l_bd, $l_bl_body);
            $builder->emit_label($l_bl_body);

            my $idx_s = $driver->alloc_local_slot();
            $builder->emit('local_store', 'void', [$idx_s, 8]);
            my $l_ll = $builder->new_label();
            my $l_ld = $builder->new_label();
            $builder->emit_label($l_ll);

            my $idx = $builder->emit('local_load', 'i64', [$idx_s]);
            my $l_ll_body = $builder->new_label();
            $builder->emit_cond_br($builder->emit('cmp_ge','Int',[$idx, 512]), $l_ld, $l_ll_body);
            $builder->emit_label($l_ll_body);

            my $mk = $builder->emit('load_mem_byte', 'Int', [$cbh, $idx]);
            my $l_hole = $builder->new_label();
            my $l_no_hole = $builder->new_label();
            $builder->emit_cond_br($builder->emit('cmp_eq','Int',[$mk, 0]), $l_hole, $l_no_hole);

            $builder->emit_label($l_hole);
            my $hp = $builder->emit('add', 'ptr', [$cbh, $builder->emit('mul','i64',[$idx, 128])]);
            $builder->emit('store_iso_disp', 'void', [0, $hp]);
            my $eidx_s = $driver->alloc_local_slot();
            $builder->emit('local_store', 'void', [$eidx_s, $builder->emit('add','i64',[$idx, 1])]);
            my $l_el = $builder->new_label();
            my $l_ed = $builder->new_label();
            $builder->emit_label($l_el);
            my $eidx = $builder->emit('local_load', 'i64', [$eidx_s]);
            my $l_el_body = $builder->new_label();
            $builder->emit_cond_br($builder->emit('cmp_ge','Int',[$eidx, 512]), $l_ed, $l_el_body);
            $builder->emit_label($l_el_body);
            my $emk = $builder->emit('load_mem_byte', 'Int', [$cbh, $eidx]);
            my $l_el_next = $builder->new_label();
            $builder->emit_cond_br($builder->emit('cmp_ne','Int',[$emk, 0]), $l_ed, $l_el_next);
            $builder->emit_label($l_el_next);
            $builder->emit('local_store', 'void', [$eidx_s, $builder->emit('add','i64',[$eidx, 1])]);
            $builder->emit_jump($l_el);
            $builder->emit_label($l_ed);
            my $final_idx = $builder->emit('local_load', 'i64', [$eidx_s]);
            $builder->emit('store_iso_disp', 'void', [8, $builder->emit('add','ptr',[$cbh, $builder->emit('mul','i64',[$final_idx, 128])])]);
            $builder->emit('leave_func', 'void', [0]);

            $builder->emit_label($l_no_hole);
            $builder->emit('local_store', 'void', [$idx_s, $builder->emit('add','i64',[$idx, 1])]);
            $builder->emit_jump($l_ll);

            $builder->emit_label($l_ld);
            $builder->emit('local_store', 'void', [$bh_s, $builder->emit('load_mem_disp','ptr',[$cbh, 0])]);
            $builder->emit_jump($l_bl);

            $builder->emit_label($l_bd);
            $builder->emit('store_iso_disp', 'void', [0, 0]);
            $builder->emit('store_iso_disp', 'void', [8, 0]);
            $builder->emit('leave_func', 'void', [0]);
        }

        method inject_runtime_gc_collect() {
            $driver->reset_locals();
            $builder->emit_label('M_gc_collect');
            $builder->emit('enter_func', 'void', []);
            $builder->emit('store_iso_disp', 'void', [80, $builder->emit('add','i64',[$builder->emit('load_iso_disp', 'i64', [80]), 1])]);
            my $bh_s = $driver->alloc_local_slot();
            $builder->emit('local_store', 'void', [$bh_s, $builder->emit('load_iso_disp','ptr',[40])]);

            my $l_c1 = $builder->new_label();
            my $l_c2 = $builder->new_label();
            $builder->emit_label($l_c1);

            my $cbh = $builder->emit('local_load', 'ptr', [$bh_s]);
            my $l_c1_body = $builder->new_label();
            $builder->emit_cond_br($builder->emit('cmp_eq','Int',[$cbh, 0]), $l_c2, $l_c1_body);
            $builder->emit_label($l_c1_body);

            my $bm_s = $driver->alloc_local_slot();
            $builder->emit('local_store', 'void', [$bm_s, 8]);
            my $l_cl = $builder->new_label();
            my $l_ce = $builder->new_label();
            $builder->emit_label($l_cl);

            my $bo = $builder->emit('local_load','i64',[$bm_s]);
            my $l_cl_body = $builder->new_label();
            $builder->emit_cond_br($builder->emit('cmp_ge','Int',[$bo, 520]), $l_ce, $l_cl_body);
            $builder->emit_label($l_cl_body);

            $builder->emit('store_mem_byte', 'void', [$cbh, $bo, 0]);
            $builder->emit('local_store', 'void', [$bm_s, $builder->emit('add','i64',[$bo, 1])]);
            $builder->emit_jump($l_cl);
            $builder->emit_label($l_ce);

            $builder->emit('local_store', 'void', [$bh_s, $builder->emit('load_mem_disp','ptr',[$cbh, 0])]);
            $builder->emit_jump($l_c1);
            $builder->emit_label($l_c2);

            my $fs = $driver->alloc_local_slot();
            $builder->emit('local_store', 'void', [$fs, $builder->emit('load_iso_disp','ptr',[32])]);
            my $l_fl = $builder->new_label();
            my $l_fd = $builder->new_label();
            $builder->emit_label($l_fl);

            my $fib = $builder->emit('local_load','ptr',[$fs]);
            my $l_fl_body = $builder->new_label();
            $builder->emit_cond_br($builder->emit('cmp_eq','Int',[$fib, 0]), $l_fd, $l_fl_body);
            $builder->emit_label($l_fl_body);

            $builder->emit('call_func', 'void', ['M_gc_mark_obj', $fib]);
            my $cur_s = $driver->alloc_local_slot();
            $builder->emit('local_store', 'void', [$cur_s, $builder->emit('load_mem_disp', 'ptr', [$fib, 24])]);

            my $l_sl = $builder->new_label();
            my $l_sd = $builder->new_label();
            $builder->emit_label($l_sl);

            my $cs = $builder->emit('local_load','ptr',[$cur_s]);
            my $l_sl_body = $builder->new_label();
            $builder->emit_cond_br($builder->emit('cmp_ge','Int',[$cs, $builder->emit('load_mem_disp','ptr',[$fib, 32])]), $l_sd, $l_sl_body);
            $builder->emit_label($l_sl_body);

            $builder->emit('call_func', 'void', ['M_gc_mark_obj', $builder->emit('load_mem_disp','ptr',[$cs,0])]);
            $builder->emit('local_store', 'void', [$cur_s, $builder->emit('add','ptr',[$cs, 8])]);
            $builder->emit_jump($l_sl);
            $builder->emit_label($l_sd);

            $builder->emit('local_store', 'void', [$fs, $builder->emit('load_mem_disp','ptr',[$fib, 48])]);
            $builder->emit_jump($l_fl);
            $builder->emit_label($l_fd);

            my $stm = $builder->emit('load_iso_disp','ptr',[16]);
            for(my $i=0; $i<$state_count; $i++){
                $builder->emit('call_func','void',['M_gc_mark_obj',$builder->emit('load_mem_disp','ptr',[$stm, 4096+($i*8)])]);
            }
            $builder->emit('call_func', 'void', ['M_gc_sweep']);
            $builder->emit('leave_func', 'void', [0]);
        }

        method inject_runtime_gc_alloc() {
            $driver->reset_locals();
            $builder->emit_label('M_gc_alloc');
            $builder->emit('enter_func', 'void', []);

            my $sz_slot = $driver->alloc_local_slot();
            my $psz = $builder->emit('get_arg', 'i64', [0]);
            my $sz_raw = $builder->emit('and', 'i64', [$builder->emit('add','i64',[$builder->emit('and', 'i64', [$psz, $builder->emit('constant','i64',[hex("FFFFFFFFFF")])]), 15]), $builder->emit('constant','i64',[-8])]);
            $builder->emit('local_store', 'void', [$sz_slot, $sz_raw]);

            my $cyc = $builder->emit('and', 'i64', [$builder->emit('load_iso_disp','i64',[80]), 0xFF]);
            my $hdr = $builder->emit('or', 'i64', [$builder->emit('local_load','i64',[$sz_slot]), $builder->emit('shl','i64',[$cyc, 40])]);
            my $fhdr_slot = $driver->alloc_local_slot();
            $builder->emit('local_store', 'void', [$fhdr_slot, $builder->emit('or', 'i64', [$hdr, $builder->emit('and','i64',[$psz, $builder->emit('constant','i64',[hex("C000000000000000")])])])]);

            my $rs = $driver->alloc_local_slot();
            my $l_f = $builder->new_label(); my $l_s = $builder->new_label();

            my $ap_slot = $driver->alloc_local_slot();
            $builder->emit('local_store', 'void', [$ap_slot, $builder->emit('load_iso_disp','ptr',[0])]);

            $builder->emit_cond_br($builder->emit('cmp_lt','Int',[$builder->emit('add','ptr',[$builder->emit('local_load','ptr',[$ap_slot]), $builder->emit('local_load','i64',[$sz_slot])]), $builder->emit('load_iso_disp','ptr',[8])]), $l_f, $l_s);
            $builder->emit_label($l_f);

            $builder->emit('store_iso_disp','void',[0, $builder->emit('add','ptr',[$builder->emit('local_load','ptr',[$ap_slot]),$builder->emit('local_load','i64',[$sz_slot])])]);
            $builder->emit('store_mem_disp','void',[$builder->emit('local_load','ptr',[$ap_slot]),0,$builder->emit('local_load','i64',[$fhdr_slot])]);
            $builder->emit('local_store', 'void', [$rs, $builder->emit('local_load','ptr',[$ap_slot])]);
            my $l_z = $builder->new_label(); $builder->emit_jump($l_z);

            $builder->emit_label($l_s);
            $builder->emit('call_func', 'void', ['M_gc_collect']);
            $builder->emit('local_store', 'void', [$ap_slot, $builder->emit('load_iso_disp','ptr',[0])]);

            my $l_f2 = $builder->new_label(); my $l_s2 = $builder->new_label();
            $builder->emit_cond_br($builder->emit('cmp_lt','Int',[$builder->emit('add','ptr',[$builder->emit('local_load','ptr',[$ap_slot]), $builder->emit('local_load','i64',[$sz_slot])]), $builder->emit('load_iso_disp','ptr',[8])]), $l_f2, $l_s2);
            $builder->emit_label($l_f2);

            $builder->emit('store_iso_disp','void',[0, $builder->emit('add','ptr',[$builder->emit('local_load','ptr',[$ap_slot]),$builder->emit('local_load','i64',[$sz_slot])])]);
            $builder->emit('store_mem_disp','void',[$builder->emit('local_load','ptr',[$ap_slot]),0,$builder->emit('local_load','i64',[$fhdr_slot])]);
            $builder->emit('local_store', 'void', [$rs, $builder->emit('local_load','ptr',[$ap_slot])]);
            $builder->emit_jump($l_z);

            $builder->emit_label($l_s2);
            my $raw_slot = $driver->alloc_local_slot();
            $builder->emit('local_store', 'void', [$raw_slot, $builder->emit('intrinsic_alloc', 'ptr', [131072])]);
            my $fr_slot = $driver->alloc_local_slot();
            $builder->emit('local_store', 'void', [$fr_slot, $builder->emit('and', 'i64', [$builder->emit('add','ptr',[$builder->emit('local_load','ptr',[$raw_slot]), 65535]), $builder->emit('constant', 'i64', [hex("FFFFFFFFFFFF0000")])])]);
            $builder->emit('store_mem_disp','void',[$builder->emit('local_load','ptr',[$fr_slot]), 0, $builder->emit('load_iso_disp','ptr',[40])]);
            $builder->emit('store_iso_disp', 'void', [40, $builder->emit('local_load','ptr',[$fr_slot])]);

            my $mz = $driver->alloc_local_slot(); $builder->emit('local_store', 'void', [$mz, $builder->emit('local_load','ptr',[$fr_slot])]);
            my $l_mzl = $builder->new_label(); my $l_mze = $builder->new_label();
            $builder->emit_label($l_mzl);
            my $cmz = $builder->emit('local_load','ptr',[$mz]);

            my $l_mzl_body = $builder->new_label();
            $builder->emit_cond_br($builder->emit('cmp_lt','Int',[$cmz, $builder->emit('add','ptr',[$builder->emit('local_load','ptr',[$fr_slot]), 1024])]), $l_mzl_body, $l_mze);
            $builder->emit_label($l_mzl_body);

            $builder->emit('store_mem_disp','void',[$cmz,0,0]);
            $builder->emit('local_store','void',[$mz, $builder->emit('add','ptr',[$cmz, 8])]);
            $builder->emit_jump($l_mzl);
            $builder->emit_label($l_mze);

            my $st_slot = $driver->alloc_local_slot();
            $builder->emit('local_store', 'void', [$st_slot, $builder->emit('add','ptr',[$builder->emit('local_load','ptr',[$fr_slot]), 1024])]);
            $builder->emit('store_mem_disp','void',[$builder->emit('local_load','ptr',[$st_slot]), 0, $builder->emit('local_load','i64',[$fhdr_slot])]);
            $builder->emit('store_iso_disp','void',[0, $builder->emit('add','ptr',[$builder->emit('local_load','ptr',[$st_slot]),$builder->emit('local_load','i64',[$sz_slot])])]);
            $builder->emit('store_iso_disp','void',[8, $builder->emit('add','ptr',[$builder->emit('local_load','ptr',[$fr_slot]), 65536])]);
            $builder->emit('local_store', 'void', [$rs, $builder->emit('local_load','ptr',[$st_slot])]);

            $builder->emit_label($l_z);
            my $res_slot = $driver->alloc_local_slot();
            $builder->emit('local_store', 'void', [$res_slot, $builder->emit('local_load','ptr',[$rs])]);
            my $obj_slot = $driver->alloc_local_slot();
            $builder->emit('local_store', 'void', [$obj_slot, $builder->emit('add','ptr',[$builder->emit('local_load','ptr',[$res_slot]), 8])]);
            my $zp = $driver->alloc_local_slot(); $builder->emit('local_store', 'void', [$zp, $builder->emit('local_load','ptr',[$obj_slot])]);
            my $l_zl = $builder->new_label(); my $l_ze = $builder->new_label();
            $builder->emit_label($l_zl);

            my $l_zl_body = $builder->new_label();
            $builder->emit_cond_br($builder->emit('cmp_lt','Int',[$builder->emit('local_load','ptr',[$zp]), $builder->emit('add','ptr',[$builder->emit('local_load','ptr',[$res_slot]), $builder->emit('local_load','i64',[$sz_slot])])]), $l_zl_body, $l_ze);
            $builder->emit_label($l_zl_body);

            $builder->emit('store_mem_disp','void',[$builder->emit('local_load','ptr',[$zp]), 0, 0]);
            $builder->emit('local_store', 'void', [$zp, $builder->emit('add','ptr',[$builder->emit('local_load','ptr',[$zp]), 8])]);
            $builder->emit_jump($l_zl);
            $builder->emit_label($l_ze);

            $builder->emit('leave_func', 'void', [$builder->emit('local_load','ptr',[$obj_slot])]);
        }

        method inject_runtime_print_int() {
            $driver->reset_locals();
            $builder->emit_label('M_print_int');
            $builder->emit('enter_func', 'void', []);
            my $n = $builder->emit('div', 'i64', [$builder->emit('sub','i64',[$builder->emit('get_arg', 'i64', [0]),1]), 2]);

            my $l_z = $builder->new_label(); my $l_nz = $builder->new_label();
            $builder->emit_cond_br($builder->emit('cmp_eq','Int',[$n, 0]), $l_z, $l_nz);
            $builder->emit_label($l_z);
            $builder->emit('intrinsic_print_char','void',[48]);
            $builder->emit('leave_func','void',[0]);

            $builder->emit_label($l_nz);
            my $scratch_start_slot = $driver->alloc_local_slot();
            for (1..3) { $driver->alloc_local_slot(); }
            my $bp = $builder->emit('get_bp', 'ptr', []);
            my $temp_buf = $builder->emit('sub', 'ptr', [$bp, $scratch_start_slot]);
            my $is = $driver->alloc_local_slot(); $builder->emit('local_store','void',[$is, 0]);
            my $ns = $driver->alloc_local_slot(); $builder->emit('local_store','void',[$ns, $n]);
            my $l1 = $builder->new_label(); my $l2 = $builder->new_label();
            $builder->emit_label($l1);

            my $cn = $builder->emit('local_load','i64',[$ns]);
            my $ci = $builder->emit('local_load','i64',[$is]);
            $builder->emit('store_mem_byte','void',[$temp_buf, $ci, $builder->emit('add','i64',[$builder->emit('mod','i64',[$cn, 10]), 48])]);
            $builder->emit('local_store','void',[$is, $builder->emit('add','i64',[$ci, 1])]);
            my $nn = $builder->emit('div','i64',[$cn, 10]);
            $builder->emit('local_store','void',[$ns, $nn]);

            $builder->emit_cond_br($builder->emit('cmp_gt','Int',[$nn, 0]), $l1, $l2);
            $builder->emit_label($l2);

            my $l3 = $builder->new_label(); my $l4 = $builder->new_label();
            $builder->emit_label($l3);
            my $fci = $builder->emit('sub','i64',[$builder->emit('local_load','i64',[$is]), 1]);
            $builder->emit('local_store','void',[$is, $fci]);
            $builder->emit('intrinsic_print_char','void',[$builder->emit('load_mem_byte','Int',[$temp_buf, $fci])]);

            $builder->emit_cond_br($builder->emit('cmp_gt','Int',[$fci, 0]), $l3, $l4);
            $builder->emit_label($l4);
            $builder->emit('leave_func','void',[0]);
        }

        method inject_runtime_print_any() {
            $driver->reset_locals();
            $builder->emit_label('M_print_any');
            $builder->emit('enter_func', 'void', []);
            my $v = $builder->emit('get_arg','i64',[0]);

            my $l_t = $builder->new_label(); my $l_f = $builder->new_label();
            $builder->emit_cond_br($builder->emit('and','i64',[$v,1]), $l_t, $l_f);

            $builder->emit_label($l_t);
            $builder->emit('call_func','void',['M_print_int',$v]);
            $builder->emit('leave_func','void',[0]);

            $builder->emit_label($l_f);
            $builder->emit('intrinsic_print','void',[$v]);
            $builder->emit('leave_func','void',[0]);
        }

        method inject_runtime_new_fiber() {
            $driver->reset_locals();
            $builder->emit_label('M_fiber_new');
            $builder->emit('enter_func', 'void', []);
            my $fp_slot = $driver->alloc_local_slot();
            $builder->emit('local_store', 'void', [$fp_slot, $builder->emit('get_arg','i64',[0])]);
            my $fcb_slot = $driver->alloc_local_slot();
            $builder->emit('local_store', 'void', [$fcb_slot, $builder->emit('call_func','ptr',['M_gc_alloc', $builder->emit('constant','i64',[64 | hex("C000000000000000")])])]);
            $builder->emit('shadow_push','void',[$builder->emit('local_load','ptr',[$fcb_slot])]);
            $builder->emit('store_mem_disp','void',[$builder->emit('local_load','ptr',[$fcb_slot]), 56, $builder->emit('intrinsic_create_wait_handle','ptr',[])]);
            my $sm = $builder->emit('intrinsic_alloc','ptr',[2097152]);
            my $tp = $builder->emit('and','i64',[$builder->emit('add','ptr',[$sm, 2097152]), $builder->emit('constant','i64',[hex("FFFFFFFFFFFFFFF0")])]);
            my $rs = $builder->emit('sub','ptr',[$tp, ($driver->arch eq 'x64' ? 48 : 0)]);
            $builder->emit('store_mem_disp','void',[$rs,0,$builder->emit('local_load','i64',[$fp_slot])]);
            $builder->emit('store_mem_disp','void',[$builder->emit('local_load','ptr',[$fcb_slot]), 0, $builder->emit('sub','ptr',[$rs, $driver->context_size()])]);
            $builder->emit('store_mem_disp','void',[$builder->emit('local_load','ptr',[$fcb_slot]), 8, $tp]);
            my $sh = $builder->emit('intrinsic_alloc','ptr',[1048576]);
            $builder->emit('store_mem_disp','void',[$builder->emit('local_load','ptr',[$fcb_slot]), 24, $sh]);
            $builder->emit('store_mem_disp','void',[$builder->emit('local_load','ptr',[$fcb_slot]), 32, $sh]);
            my $is = $builder->emit('get_isolate_ctx','ptr',[]);
            $builder->emit('store_mem_disp','void',[$builder->emit('local_load','ptr',[$fcb_slot]), 48, $builder->emit('load_mem_disp', 'ptr', [$is, 32])]);
            $builder->emit('store_mem_disp', 'void', [$is, 32, $builder->emit('local_load','ptr',[$fcb_slot])]);
            $builder->emit('shadow_pop','void',[]);
            $builder->emit('leave_func','void',[$builder->emit('local_load','ptr',[$fcb_slot])]);
        }

        method inject_runtime_concat() {
            $driver->reset_locals();
            $builder->emit_label('M_concat');
            $builder->emit('enter_func', 'void', []);
            my $s1_slot=$driver->alloc_local_slot(); $builder->emit('local_store','void',[$s1_slot, $builder->emit('get_arg','ptr', [0])]);
            my $s2_slot=$driver->alloc_local_slot(); $builder->emit('local_store','void',[$s2_slot, $builder->emit('get_arg','ptr', [1])]);
            $builder->emit('shadow_push','void',[$builder->emit('local_load','ptr',[$s1_slot])]);
            $builder->emit('shadow_push','void',[$builder->emit('local_load','ptr',[$s2_slot])]);
            my $l1_slot=$driver->alloc_local_slot(); $builder->emit('local_store','void',[$l1_slot, $builder->emit('load_mem_disp','i64',[$builder->emit('local_load','ptr',[$s1_slot]),0])]);
            my $l2_slot=$driver->alloc_local_slot(); $builder->emit('local_store','void',[$l2_slot, $builder->emit('load_mem_disp','i64',[$builder->emit('local_load','ptr',[$s2_slot]),0])]);
            my $tl_slot=$driver->alloc_local_slot(); $builder->emit('local_store','void',[$tl_slot, $builder->emit('add','i64',[$builder->emit('local_load','i64',[$l1_slot]),$builder->emit('local_load','i64',[$l2_slot])])]);
            my $ns_slot=$driver->alloc_local_slot(); $builder->emit('local_store','void',[$ns_slot, $builder->emit('call_func','ptr',['M_gc_alloc', $builder->emit('or','i64',[$builder->emit('add','i64',[$builder->emit('local_load','i64',[$tl_slot]),24]), $builder->emit('constant','i64',[hex("C000000000000000")])])])]);
            $builder->emit('shadow_push','void',[$builder->emit('local_load','ptr',[$ns_slot])]);
            $builder->emit('store_mem_disp','void',[$builder->emit('local_load','ptr',[$ns_slot]),0,$builder->emit('local_load','i64',[$tl_slot])]);

            my $i_slot=$driver->alloc_local_slot(); $builder->emit('local_store','void',[$i_slot,0]);
            my $l1s=$builder->new_label(); my $l1e=$builder->new_label(); $builder->emit_label($l1s);
            my $ci=$builder->emit('local_load','i64',[$i_slot]);

            my $l1s_body=$builder->new_label();
            $builder->emit_cond_br($builder->emit('cmp_lt','Int',[$ci,$builder->emit('local_load','i64',[$l1_slot])]),$l1s_body,$l1e);
            $builder->emit_label($l1s_body);

            $builder->emit('store_mem_byte','void',[$builder->emit('local_load','ptr',[$ns_slot]),$builder->emit('add','i64',[$ci,16]),$builder->emit('load_mem_byte','i64',[$builder->emit('local_load','ptr',[$s1_slot]),$builder->emit('add','i64',[$ci,16])])]);
            $builder->emit('local_store','void',[$i_slot,$builder->emit('add','i64',[$ci,1])]);
            $builder->emit_jump($l1s);
            $builder->emit_label($l1e);
            $builder->emit('local_store','void',[$i_slot,0]);

            my $l2s=$builder->new_label(); my $l2e=$builder->new_label(); $builder->emit_label($l2s);
            my $cj=$builder->emit('local_load','i64',[$i_slot]);

            my $l2s_body=$builder->new_label();
            $builder->emit_cond_br($builder->emit('cmp_lt','Int',[$cj,$builder->emit('local_load','i64',[$l2_slot])]),$l2s_body,$l2e);
            $builder->emit_label($l2s_body);

            $builder->emit('store_mem_byte','void',[$builder->emit('local_load','ptr',[$ns_slot]),$builder->emit('add','i64',[$builder->emit('add','i64',[$cj,16]),$builder->emit('local_load','i64',[$l1_slot])]),$builder->emit('load_mem_byte','i64',[$builder->emit('local_load','ptr',[$s2_slot]),$builder->emit('add','i64',[$cj,16])])]);
            $builder->emit('local_store','void',[$i_slot,$builder->emit('add','i64',[$cj,1])]);
            $builder->emit_jump($l2s);
            $builder->emit_label($l2e);

            $builder->emit('shadow_pop','void',[]); $builder->emit('shadow_pop','void',[]); $builder->emit('shadow_pop','void',[]);
            $builder->emit('leave_func','void',[$builder->emit('local_load','ptr',[$ns_slot])]);
        }

        method inject_runtime_to_string() {
            $driver->reset_locals();
            $builder->emit_label('M_any_to_str');
            $builder->emit('enter_func', 'void', []);
            my $v_slot=$driver->alloc_local_slot();
            $builder->emit('local_store','void',[$v_slot, $builder->emit('get_arg','i64',[0])]);

            my $l_t1 = $builder->new_label(); my $l_f1 = $builder->new_label();
            $builder->emit_cond_br($builder->emit('and','i64',[$builder->emit('local_load','i64',[$v_slot]),1]),$l_t1,$l_f1);
            $builder->emit_label($l_f1);
            $builder->emit('leave_func','void',[$builder->emit('local_load','i64',[$v_slot])]);

            $builder->emit_label($l_t1);
            my $n=$builder->emit('div','i64',[$builder->emit('sub','i64',[$builder->emit('local_load','i64',[$v_slot]),1]),2]);
            my $l_t2 = $builder->new_label(); my $l_f2 = $builder->new_label();
            $builder->emit_cond_br($builder->emit('cmp_eq','Int',[$n,0]),$l_t2,$l_f2);
            $builder->emit_label($l_t2);
            $builder->emit('leave_func','void',[$builder->emit('load_data_addr','ptr',[$data_segment->add_string("0")])]);

            $builder->emit_label($l_f2);
            my $bs=$driver->alloc_local_slot(); for(1..3){$driver->alloc_local_slot()}
            my $buf=$builder->emit('sub','ptr',[$builder->emit('get_bp','ptr',[]),$bs]);
            my $is=$driver->alloc_local_slot(); $builder->emit('local_store','void',[$is,0]);
            my $ns=$driver->alloc_local_slot(); $builder->emit('local_store','void',[$ns,$n]);
            my $l1 = $builder->new_label(); my $l2 = $builder->new_label(); $builder->emit_label($l1);
            my $cn = $builder->emit('local_load','i64',[$ns]); my $ci = $builder->emit('local_load','i64',[$is]);
            $builder->emit('store_mem_byte','void',[$buf,$ci,$builder->emit('add','i64',[$builder->emit('mod','i64',[$cn, 10]),48])]);
            $builder->emit('local_store','void',[$is,$builder->emit('add','i64',[$ci,1])]);
            my $nn = $builder->emit('div','i64',[$cn,10]); $builder->emit('local_store','void',[$ns,$nn]);
            $builder->emit_cond_br($builder->emit('cmp_gt','Int',[$nn,0]),$l1,$l2); $builder->emit_label($l2);
            my $sl_slot=$driver->alloc_local_slot();
            $builder->emit('local_store','void',[$sl_slot, $builder->emit('local_load','i64',[$is])]);
            my $ns_ptr=$builder->emit('call_func','ptr',['M_gc_alloc', $builder->emit('or','i64',[$builder->emit('add','i64',[$builder->emit('local_load','i64',[$sl_slot]),24]), $builder->emit('constant','i64',[hex("C000000000000000")])])]);
            my $ns_p_slot = $driver->alloc_local_slot();
            $builder->emit('local_store', 'void', [$ns_p_slot, $ns_ptr]);
            $builder->emit('shadow_push','void',[$builder->emit('local_load','ptr',[$ns_p_slot])]);
            $builder->emit('store_mem_disp','void',[$builder->emit('local_load','ptr',[$ns_p_slot]),0,$builder->emit('local_load','i64',[$sl_slot])]);
            $builder->emit('store_mem_disp','void',[$builder->emit('local_load','ptr',[$ns_p_slot]),8,$builder->emit('local_load','i64',[$sl_slot])]);
            my $cs=$driver->alloc_local_slot(); $builder->emit('local_store','void',[$cs,0]);
            my $l3 = $builder->new_label(); my $l4 = $builder->new_label(); $builder->emit_label($l3);
            my $cci = $builder->emit('local_load','i64',[$cs]);

            my $l_f3 = $builder->new_label();
            $builder->emit_cond_br($builder->emit('cmp_ge','Int',[$cci,$builder->emit('local_load','i64',[$sl_slot])]),$l4,$l_f3);
            $builder->emit_label($l_f3);

            $builder->emit('store_mem_byte','void',[$builder->emit('local_load','ptr',[$ns_p_slot]),$builder->emit('add','i64',[$cci,16]),$builder->emit('load_mem_byte','i64',[$buf,$builder->emit('sub','i64',[$builder->emit('sub','i64',[$builder->emit('local_load','i64',[$sl_slot]),1]),$cci])])]);
            $builder->emit('local_store','void',[$cs,$builder->emit('add','i64',[$cci,1])]); $builder->emit_jump($l3);
            $builder->emit_label($l4); $builder->emit('shadow_pop','void',[]); $builder->emit('leave_func','void',[$builder->emit('local_load','ptr',[$ns_p_slot])]);
        }

        method _emit_runtime_init_sub() {
            $builder->emit_label('M_runtime_init'); $builder->emit( 'enter_func', 'void', [] );
            my $giso_ptr = $builder->emit( 'load_data_addr', 'ptr', [ $driver->global_iso_offset ] );

            my $l_t = $builder->new_label(); my $l_f = $builder->new_label();
            $builder->emit_cond_br($builder->emit('cmp_ne','Int',[$builder->emit('load_mem_disp','i64',[$giso_ptr,0]), 0]), $l_t, $l_f);

            $builder->emit_label($l_t);
            $builder->emit('leave_func','void',[0]);

            $builder->emit_label($l_f);
            my $iso=$builder->emit('intrinsic_alloc','ptr',[1024]);
            $builder->emit('set_isolate_ctx','void',[$iso]);
            $builder->emit('store_mem_disp','void',[$giso_ptr,0,$iso]);

            my $ms=$builder->emit('intrinsic_alloc','ptr',[1048576]);
            $builder->emit('store_iso_disp','void',[104,$ms]);
            $builder->emit('store_iso_disp','void',[112,$ms]);
            $builder->emit('store_iso_disp','void',[120,$builder->emit('add','ptr',[$ms,1048576])]);

            my $raw_heap=$builder->emit('intrinsic_alloc','ptr',[131072]);
            my $mask = $builder->emit('constant', 'i64', [ hex("FFFFFFFFFFFF0000") ]);
            my $hp=$builder->emit('and','i64',[$builder->emit('add','ptr',[$raw_heap,65535]), $mask]);
            $builder->emit('store_iso_disp','void',[40,$hp]);
            $builder->emit('store_iso_disp','void',[88,$hp]);
            $builder->emit('store_iso_disp','void',[96,$builder->emit('add','ptr',[$hp,65536])]);
            $builder->emit('store_iso_disp','void',[0,$builder->emit('add','ptr',[$hp,1024])]);
            $builder->emit('store_iso_disp','void',[8,$builder->emit('add','ptr',[$hp,65536])]);
            $builder->emit('store_iso_disp','void',[80,$builder->emit('constant','i64',[1])]);

            my $stm=$builder->emit('intrinsic_alloc','ptr',[1048576]);
            $builder->emit('store_iso_disp','void',[16,$stm]);
            my $fcb=$builder->emit('call_func','ptr',['M_gc_alloc',$builder->emit('constant','i64',[64 | hex("C000000000000000")])]);
            $builder->emit('store_iso_disp','void',[24,$fcb]);
            $builder->emit('store_mem_disp','void',[$iso,32,$fcb]);
            my $sh=$builder->emit('intrinsic_alloc','ptr',[1048576]);
            $builder->emit('store_mem_disp','void',[$fcb,24,$sh]);
            $builder->emit('store_mem_disp','void',[$fcb,32,$sh]);
            $builder->emit('store_mem_disp','void',[$fcb,56,$builder->emit('intrinsic_create_wait_handle','ptr',[])]);
            $builder->emit('leave_func','void',[0]);
        }

        # --- AST Lowering Dispatcher ---

        method lower($node) {
            return (undef,'void') unless defined $node;
            my $nt=ref($node); $nt=~s/.*:://; my $m="lower_$nt";
            return $self->$m($node) if $self->can($m); die "Lowering Error: No handler for node type $nt";
        }

method lower_program($nodes) {
            # 1. Attach data segment to driver so Codegen can patch it later
            $driver->set_data_segment($data_segment);

            # 2. Reserve slots in the data segment for the Isolate pointer
            # and the Exception Table offset.
            $driver->set_global_iso_offset($data_segment->add_raw_bytes("\0" x 8));
            $driver->set_exception_table_offset($data_segment->add_raw_bytes("\0" x 8));

            # 3. Standard entry sequence: Jump to main logic, skip over runtimes
            $builder->emit_jump('L_MAIN_START');

            # 4. Inject runtime components (GC, Print, Fibers, and the Unwinder)
            $self->inject_runtime();
            $self->_emit_runtime_init_sub();

            # 5. Metadata Pass: Scan nodes to register class structures
            $self->register_classes($nodes);

            # 6. Global Pass: Lower all non-executable definitions (Methods, Classes, Native)
            my @main_statements;
            for my $n (@$nodes) {
                if ($n isa Brocken::AST::OOP::Method ||
                    $n isa Brocken::AST::OOP::ClassDecl ||
                    $n isa Brocken::AST::NativeDecl) {
                    $self->lower($n);
                } else {
                    push @main_statements, $n;
                }
            }

            # --- START OF MAIN EXECUTABLE LOGIC ---
            $builder->emit_label('L_MAIN_START');
            $builder->emit('enter_func', 'void', []);

            # One-time allocation of heap, mark stack, and state map
            $builder->emit('call_func', 'void', ["M_runtime_init"]);

            # Load the Isolate pointer from its fixed slot in the data segment
            my $iso_slot = $builder->emit('load_data_addr', 'ptr', [$driver->global_iso_offset]);
            my $iso      = $builder->emit('load_mem_disp',  'i64', [$iso_slot, 0]);
            $builder->emit('set_isolate_ctx', 'void', [$iso]);

            # --- CRITICAL FIX: Exception Table Absolute Pointer ---
            # During Codegen, an offset is written to $driver->exception_table_offset.
            # We must convert that offset into a real memory address at startup.
            my $extab_off_ptr = $builder->emit('load_data_addr', 'ptr', [$driver->exception_table_offset]);
            my $extab_off     = $builder->emit('load_mem_disp', 'i64', [$extab_off_ptr, 0]);
            my $data_base     = $builder->emit('load_data_addr', 'ptr', [0]);

            # Absolute Address = Data Base + Offset
            my $extab_ptr = $builder->emit('add', 'ptr', [$data_base, $extab_off]);

            # Store absolute pointer in the Isolate (offset 128) for M_unwind to use
            $builder->emit('store_iso_disp', 'void', [$driver->iso_offset('exception_table'), $extab_ptr]);

            # 7. Establish the stack base for the main fiber (offset 8 in FCB)
            # This allows the Unwinder and GC to know where the stack roots end.
            my $fcb = $builder->emit('load_iso_disp', 'ptr', [$driver->iso_offset('current_fcb')]);
            my $bp  = $builder->emit('get_bp', 'ptr', []);
            $builder->emit('store_mem_disp', 'void', [$fcb, $driver->fcb_offset('stack_base'), $bp]);

            # 8. VTable Initialization
            # Loop through all classes and build their method dispatch tables in the state map.
            my $stm = $builder->emit('load_iso_disp', 'ptr', [$driver->iso_offset('state_ptr')]);
            for my $cn (sort keys %class_info) {
                my $c = $class_info{$cn};
                my $ptr_count = scalar @{$c->{ptr_offsets}};

                # Allocation size: PtrOffsets count + the offsets themselves + method addresses
                my $vt_size = ($ptr_count + 1) * 8 + ($global_method_count * 8);
                my $vt = $builder->emit('intrinsic_alloc', 'ptr', [$vt_size]);

                # Align the pointer so it points to the start of the method addresses
                my $method_base = $builder->emit('add', 'ptr', [$vt, ($ptr_count + 1) * 8]);

                # Metadata for the GC: store number of pointer fields and their offsets
                $builder->emit('store_mem_disp', 'void', [$method_base, -8, $builder->emit('constant', 'i64', [$ptr_count])]);
                for (my $i = 0; $i < $ptr_count; $i++) {
                    $builder->emit('store_mem_disp', 'void', [$method_base, -16 - ($i * 8),
                                   $builder->emit('constant', 'i64', [$c->{ptr_offsets}[$i]])]);
                }

                # Populate the table with actual method function addresses
                for my $mn (@{$c->{method_names}}) {
                    my $m_addr = $builder->emit('load_func_addr', 'ptr', ["M_${cn}::$mn"]);
                    $builder->emit('store_mem_disp', 'void', [$method_base, $global_methods{$mn} * 8, $m_addr]);
                }

                # Register this VTable in the global State Map at the class's unique ID
                $builder->emit('store_mem_disp', 'void', [$stm, $c->{id} * 8, $method_base]);
            }

            # 9. Execute Main Program
            $current_func_name = 'L_MAIN_START';
            @func_locals       = ();
            $self->lower_block(\@main_statements);

            # 10. Run all top-level defer blocks before exiting
            $self->_emit_all_defers();

            # 11. Termination
            if ( $self->skip_runtime ) {
                $builder->emit( 'leave_func', 'i64', [ $builder->emit( 'constant', 'i64', [1] ) ] );
            }
            else {
                # Normal exit via system call
                $builder->emit( 'intrinsic_exit', 'void', [ $builder->emit( 'constant', 'i64', [0] ) ] );
            }

            # 12. Fragment Stitching
            # Append all lazily generated code (anonymous subs, fiber blocks)
            while (@fragments) {
                my $f = shift @fragments;
                $builder->push_instruction($_) for @$f;
            }

            # 13. AOT Finalization
            # Emit target-specific assembly for fiber context switching and fault handlers.
            $builder->emit('intrinsic_emit_runtime', 'void', []) unless $self->skip_runtime;
        }
        method lower_Const($node) {
            if($node->type eq 'String'){ return ($builder->emit('load_data_addr','ptr',[$data_segment->add_string($node->value)]),'String') }
            if($node->type eq 'Class'){ return ($builder->emit('constant','i64',[0]),$node->value) }
            if($node->type eq 'i64' || $node->type eq 'ptr'){ return ($builder->emit('constant',$node->type,[$node->value]),$node->type) }
            if ($node->type eq 'Float' || $node->type eq 'double') { return ($builder->emit('constant','double',[unpack('Q<',pack('d<',$node->value))]),'Float') }
            return ($builder->emit('constant','i64',[($node->value<<1)|1]),'Int');
        }

        method lower_Var($node) {
            my $s=$current_scope->resolve($node->name)//die "Undeclared variable: ".$node->name;
            if(defined $s->stack_offset && $s->stack_offset<0){
                my $sl_ptr = $builder->emit('local_load','ptr',[$current_scope->resolve('$self')->stack_offset]);
                return ($builder->emit('load_mem_disp','Any',[$sl_ptr,abs($s->stack_offset)]),'Any')
            }
            if($s->is_state){ return ($builder->emit('load_mem_disp',$s->type,[$builder->emit('load_iso_disp','ptr',[16]),4096+($s->state_idx*8)]),$s->type) }
            return ($builder->emit('local_load',$s->type,[$s->stack_offset]),$s->type);
        }

        method lower_VarDecl($node) {
            my ($vr,$vt)=$self->lower($node->value);
            my $sl=$driver->alloc_local_slot();
            my $ft=$node->type eq 'Any'?$vt:$node->type;
            my $sho=undef;
            if($ft=~/^(Any|String|Array|Fiber|Class)$/ || $ft!~/^(Int|Float|i64|double|ptr|void)$/){
                $sho=$builder->emit('shadow_get','ptr',[]);
                $builder->emit('shadow_push','void',[$vr])
            }
            $current_scope->define($node->name,$ft,0,undef,$sl,$sho);
            $builder->emit('local_store','void',[$sl,$vr]);
            return (undef,'void');
        }

        method lower_StateDecl($node) {
            my $idx = $state_count++;
            $current_scope->define( $node->name, $node->type, 1, $idx, undef );
            my $l_i = $builder->new_label();
            my $l_d = $builder->new_label();
            my $sb  = $builder->emit( 'load_iso_disp', 'ptr', [ 16 ] );
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
            my ($vr,$vt)=$self->lower($node->value);
            my $s=$current_scope->resolve($node->name)//die "Undeclared variable: ".$node->name;
            if(defined $s->stack_offset && $s->stack_offset<0){
                my $sl_ptr = $builder->emit('local_load','ptr',[$current_scope->resolve('$self')->stack_offset]);
                if($vt=~/^(Any|String|Array|Fiber|Class)$/ || $vt!~/^(Int|Float|i64|double|ptr|void)$/){
                    $self->_emit_write_barrier($sl_ptr,abs($s->stack_offset),$vr)
                } else {
                    $builder->emit('store_mem_disp','void',[$sl_ptr,abs($s->stack_offset),$vr])
                }
            }
            elsif($s->is_state){
                $builder->emit('store_mem_disp','void',[$builder->emit('load_iso_disp','ptr',[16]),4096+($s->state_idx*8),$vr])
            }
            else {
                $builder->emit('local_store','void',[$s->stack_offset,$vr]);
                if(defined $s->shadow_offset){ $builder->emit('store_mem_disp','void',[$s->shadow_offset, 0, $vr]) }
            }
            return ($vr,$s->type);
        }

        method lower_UnaryOp($node) {
            my ( $r, $t ) = $self->lower( $node->expr );
            if ( $node->op eq '!' ) {
                my $raw = $builder->emit( 'cmp_eq', 'Int', [ $r, 1 ] );
                return ( $builder->emit( 'add', 'i64', [ $builder->emit( 'mul', 'i64', [ $raw, 2 ] ), 1 ] ), 'Int' );
            }
            if ( $node->op eq '-' ) {
                my $c1  = $builder->emit( 'constant', 'i64', [1] );
                my $c2  = $builder->emit( 'constant', 'i64', [2] );
                my $val = $builder->emit( 'div',      'i64', [ $builder->emit( 'sub', 'i64', [ $r, $c1 ] ), $c2 ] );
                my $neg = $builder->emit( 'sub',      'i64', [ 0, $val ] );
                return ( $builder->emit( 'add', 'i64', [ $builder->emit( 'mul', 'i64', [ $neg, $c2 ] ), $c1 ] ), 'Int' );
            }
            die "Unary " . $node->op;
        }

        method lower_BinOp($node) {
            if ( $node->op eq '&&' || $node->op eq '||' || $node->op eq '//' ) { return $self->_lower_logical($node); }
            if($node->op eq '.'){
                my ($lr,$lt)=$self->lower($node->left); $builder->emit('shadow_push','void',[$lr]);
                my ($rr,$rt)=$self->lower($node->right); $builder->emit('shadow_push','void',[$rr]);
                my $lc=$lt eq 'String'?$lr:$builder->emit('call_func','ptr',['M_any_to_str',$lr]);
                my $rc=$rt eq 'String'?$rr:$builder->emit('call_func','ptr',['M_any_to_str',$rr]);
                my $res=$builder->emit('call_func','ptr',['M_concat',$lc,$rc]);
                $builder->emit('shadow_pop','void',[]); $builder->emit('shadow_pop','void',[]); return ($res,'String')
            }
            my ($lr,$lt)=$self->lower($node->left); my ($rr,$rt)=$self->lower($node->right);
            my $isf=($lt eq 'Float' || $rt eq 'Float' || $lt eq 'double' || $rt eq 'double');
            my $mm={'+'=>'add','-'=>'sub','*'=>'mul','/'=>'div','%'=>'mod'};
            if(exists $mm->{$node->op}){
                if($isf){return ($builder->emit($mm->{$node->op},'double',[$lr,$rr]),'Float')}
                my $lu=$builder->emit('div','i64',[$builder->emit('sub','i64',[$lr,1]),2]);
                my $ru=$builder->emit('div','i64',[$builder->emit('sub','i64',[$rr,1]),2]);
                my $res_raw = $builder->emit($mm->{$node->op},'i64',[$lu,$ru]);
                return ($builder->emit('add','i64',[$builder->emit('mul','i64',[$res_raw,2]),1]),'Int')
            }
            my $cm={'=='=>'cmp_eq','!='=>'cmp_ne','<'=>'cmp_lt','>'=>'cmp_gt','<='=>'cmp_le','>='=>'cmp_ge'};
            if(exists $cm->{$node->op}){
                my $raw=$builder->emit($cm->{$node->op},($isf?'double':'i64'),[$lr,$rr]);
                return ($builder->emit('add','i64',[$builder->emit('mul','i64',[$raw,2]),1]),'Int')
            }
            die "BinOp ".$node->op;
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
            my $sp=$builder->emit('shadow_get','ptr',[]); $current_scope=Brocken::Scope->new(parent=>$current_scope);
            my $eh=scalar @defer_stack; my ($r,$t); for my $s (@{$node->statements}){ ($r,$t)=$self->lower($s) }
            while(scalar @defer_stack > $eh){ my $f=pop @defer_stack; for my $inst (@$f){$builder->push_instruction($inst)} }
            $current_scope=$current_scope->parent; $builder->emit('shadow_set','void',[$sp]); return ($r,$t);
        }

        method lower_If($node) {
            my $l1=$builder->new_label(); my $l2=$builder->new_label(); my $l3=$builder->new_label();
            $builder->emit_cond_br($self->_emit_bool_test(($self->lower($node->condition))[0]),$l1,$l2);
            $builder->emit_label($l1); $self->lower($node->then_block); $builder->emit_jump($l3);
            $builder->emit_label($l2); $self->lower($node->else_block) if $node->else_block;
            $builder->emit_label($l3); return (undef,'void')
        }

        method lower_While($node) {
            my $l1=$builder->new_label(); my $l2=$builder->new_label(); my $l3=$builder->new_label();
            $builder->emit_label($l1); $builder->emit_cond_br($self->_emit_bool_test(($self->lower($node->condition))[0]),$l2,$l3);
            $builder->emit_label($l2); $self->lower($node->body); $builder->emit_jump($l1);
            $builder->emit_label($l3); return (undef,'void')
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
                $builder->emit( 'intrinsic_sleep', 'void', [$r] );
                return ( undef, 'void' );
            }
            if ( $node->name eq 'open' ) {
                my $path_node  = $node->args->[0] // die "open requires a path";
                my $mode_node  = $node->args->[1] // Brocken::AST::Expr::Const->new( value => "r", type => 'String' );
                my ($path_reg) = $self->lower($path_node);
                my ($mode_reg) = $self->lower($mode_node);
                my $fd         = $builder->emit( 'intrinsic_open', 'i64', [ $path_reg, $mode_reg ] );

                my $fh_sz = $builder->emit( 'constant',  'i64', [ 32 | hex("C000000000000000") ] );
                my $obj   = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', $fh_sz ] );
                $builder->emit( 'store_mem_disp', 'void', [ $obj, 8, $fd ] );
                $builder->emit( 'shadow_push',     'void', [$obj] );
                return ( $obj, 'FileHandle' );
            }
            if ( $node->name eq 'close' ) {
                my ( $fh, $ft ) = $self->lower( $node->args->[0] );
                my $fd = $builder->emit( 'load_mem_disp', 'i64', [ $fh, 8 ] );
                $builder->emit( 'intrinsic_close', 'void', [$fd] );
                return ( undef, 'void' );
            }
            if ( $node->name eq 'slurp' ) {
                my ($path_reg) = $self->lower( $node->args->[0] );
                my $mode_ptr   = $builder->emit( 'load_data_addr',     'ptr', [ $data_segment->add_string("r") ] );
                my $fd         = $builder->emit( 'intrinsic_open',     'i64', [ $path_reg, $mode_ptr ] );
                my $size       = $builder->emit( 'intrinsic_get_size', 'i64', [$fd] );
                my $tag        = $builder->emit( 'constant',           'i64', [ hex("C000000000000000") ] );
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
                    my ($fh_reg) = $self->lower( $node->args->[0] );
                    my ( $val_reg, $val_type ) = $self->lower( $node->args->[1] );
                    my $fd = $builder->emit( 'load_mem_disp', 'i64', [ $fh_reg, 8 ] );
                    if ( $val_type eq 'String' ) {
                        my $len = $builder->emit( 'load_mem_disp', 'i64', [ $val_reg, 0 ] );
                        my $ptr = $builder->emit( 'add',           'ptr', [ $val_reg, 16 ] );
                        $builder->emit( 'intrinsic_write', 'void', [ $fd, $ptr, $len ] );
                    }
                    else {
                        my $str = $builder->emit( 'call_func',     'ptr', [ 'M_any_to_str', $val_reg ] );
                        my $len = $builder->emit( 'load_mem_disp', 'i64', [ $str, 0 ] );
                        my $ptr = $builder->emit( 'add',           'ptr', [ $str, 16 ] );
                        $builder->emit( 'intrinsic_write', 'void', [ $fd, $ptr, $len ] );
                    }
                }
                else {
                    my ( $r, $t ) = $self->lower( $node->args->[0] );
                    if   ( $t eq 'String' ) { $builder->emit( 'intrinsic_print', 'void', [$r] ); }
                    else                    { $builder->emit( 'call_func',       'void', [ 'M_print_any', $r ] ); }
                }
                return ( undef, 'void' );
            }
            if($node->name eq 'say'){
                my ($r,$t)=$self->lower($node->args->[0]);
                if($t eq 'String'){$builder->emit('intrinsic_print','void',[$r])} else {$builder->emit('call_func','void',["M_print_any",$r])}
                $builder->emit('intrinsic_print','void',[$builder->emit('load_data_addr', 'ptr', [$data_segment->add_string("\n")])]);
                return (undef,'void')
            }
            if ( exists $native_funcs{ $node->name } ) {
                my $info = $native_funcs{ $node->name };
                my @args = map { ( $self->lower($_) )[0] } @{ $node->args };
                my $res  = $builder->emit( 'call_native', 'Any', [ $info->{library}, $node->name, $info->{signature}, @args ] );
                return ( $res, 'Any' );
            }
            my $sp_backup = $builder->emit( 'shadow_get', 'ptr', [] );
            my @as=map{($self->lower($_))[0]} @{$node->args};
            my $res = $builder->emit('call_func', 'i64', ["M_".$node->name,@as]);
            $builder->emit('shadow_set', 'void', [$sp_backup]);
            return ($res, 'Any');
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
            die "Semantic Error: 'return' is not allowed inside a defer block. Use logic flow to exit the block early if needed.\n"
                if $defer_active_depth > 0;
            die "Return outside sub\n" if $routine_depth == 0;
            my ($rv, $ty);
            if (defined $node->expr) { ($rv, $ty) = $self->lower($node->expr) }
            else { $rv = $builder->emit('constant', 'i64', [1]); $ty = 'Int' }
            $self->_emit_all_defers();
            if ( $routine_types[-1] eq 'fiber' ) {
                my $fcb = $builder->emit( 'load_iso_disp', 'ptr', [ 24 ] );
                $builder->emit( 'call_func', 'Any',
                    [ 'M_fiber_switch', $builder->emit( 'load_mem_disp', 'ptr', [ $fcb, 40 ] ), $rv ] );
                $builder->emit( 'intrinsic_exit', 'void', [0] );
            }
            else { $builder->emit( 'leave_func', 'void', [$rv] ); }
            return (undef, 'void');
        }

        method lower_Exit($node) {
            my $ev;
            if ( defined $node->expr ) {
                ($ev) = $self->lower( $node->expr );
            }
            else {
                $ev = $builder->emit( 'constant', 'i64', [1] );
            }
            $self->_emit_all_defers();
            $builder->emit( 'intrinsic_exit', 'void', [$ev] );
            return ( undef, 'void' );
        }

       method lower_Die($node) {
        my ($ev) = $node->exception ? $self->lower($node->exception) : ($builder->emit('constant','i64',[1]), 'Int');
        $self->_emit_all_defers();
        $builder->emit('intrinsic_throw', 'void', [$ev]);
        return (undef, 'void');
    }

    method lower_TryCatch($node) {
        my $try_id = ++$anon_counter;
        my $l_catch = $builder->new_label();
        my $l_end = $builder->new_label();
        my $l_finally = $node->finally_block ? $builder->new_label() : undef;

        $builder->emit('mark_try_start', 'void', [$try_id, $l_catch, $l_finally]);
        $self->lower($node->try_block);
        $builder->emit('mark_try_end', 'void', [$try_id]);
        $builder->emit_jump($l_finally // $l_end);

        $builder->emit_label($l_catch);
        my $exc = $builder->emit('intrinsic_get_exception', 'Any', []);
        $builder->emit('intrinsic_clear_exception', 'void', []);

        $current_scope = Brocken::Scope->new(parent => $current_scope);
        my $sl = $driver->alloc_local_slot();
        $current_scope->define($node->catch_var->{value}, 'Any', 0, undef, $sl);
        $builder->emit('local_store', 'void', [$sl, $exc]);
        $self->lower($node->catch_block);
        $current_scope = $current_scope->parent;
        $builder->emit_jump($l_finally // $l_end);

        if ($l_finally) {
            $builder->emit_label($l_finally);
            $self->lower($node->finally_block);
        }
        $builder->emit_label($l_end);
        return (undef, 'void');
    }

        method lower_MethodCall($node) {
            my $inv=$node isa Brocken::AST::Expr::MethodCall ? $node->object : $node->invocant;
            my $mn=$node isa Brocken::AST::Expr::MethodCall ? $node->method : $node->name;
            if($mn eq 'new' && $inv isa Brocken::AST::Expr::Const && $inv->type eq 'Class'){
                my $res=$builder->emit('call_func', 'ptr', ["M_".$inv->value."::new"]);
                $builder->emit('shadow_push','void',[$res]); return ($res,$inv->value)
            }
            my $sp_backup = $builder->emit( 'shadow_get', 'ptr', [] );
            my ($or,$ot)=$self->lower($inv); my @as=map{($self->lower($_))[0]} @{$node->args};
            if ( $ot eq 'Fiber' && $mn eq 'switch' ) {
                return ( $builder->emit( 'call_func', 'Any', [ 'M_fiber_switch', $or, @as ] ), 'Any' );
            }
            my $vtp = $builder->emit('load_mem_disp', 'ptr', [$or, 0]);
            my $fn=$builder->emit('load_mem_disp','ptr',[$vtp,($global_methods{$mn}//die "Unknown method $mn")*8]);
            my $res = $builder->emit('call_reg','i64',[$fn,$or,@as]);
            $builder->emit('shadow_set', 'void', [$sp_backup]);
            return ($res, 'Any');
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
            my ( $res, $ty ) = $self->lower_block( $node->body->statements );
            $self->_emit_all_defers();
            my $fcb = $builder->emit( 'load_iso_disp', 'ptr', [ 24 ] );
            $builder->emit( 'call_func', 'Any',
                [ 'M_fiber_switch', $builder->emit( 'load_mem_disp', 'ptr', [ $fcb, 40 ] ), $res // 3 ] );
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
            my $yv;
            if ( defined $node->expr ) {
                ($yv) = $self->lower( $node->expr );
            }
            else {
                $yv = $builder->emit( 'constant', 'i64', [1] );
            }
            my $fcb = $builder->emit( 'load_iso_disp', 'ptr', [ 24 ] );
            return (
                $builder->emit(
                    'call_func', 'Int', [ 'M_fiber_switch', $builder->emit( 'load_mem_disp', 'ptr', [ $fcb, 40 ] ), $yv ]
                ),
                'Int'
            );
        }

        method lower_ArrayLiteral($node) {
            my $ct  = scalar @{ $node->elements };
            my $sz  = 8 + ( $ct * 8 );
            my $arr = $builder->emit( 'call_func', 'ptr', [ 'M_gc_alloc', $builder->emit( 'constant', 'i64', [$sz] ) ] );
            $builder->emit( 'shadow_push', 'void', [$arr] );
            $builder->emit( 'store_mem_disp', 'void', [ $arr, 0, $builder->emit( 'constant', 'i64', [ ( $ct << 1 ) | 1 ] ) ] );
            my $ix = 0;
            for my $el ( @{ $node->elements } ) {
                my ( $vr, $vt ) = $self->lower($el);
                my $off = 8 + ( $ix++ * 8 );
                if ( $vt =~ /^(Any|String|Array|Fiber|Class)$/ || $vt !~ /^(Int|Float|i64|double|ptr|void)$/ ) {
                    $self->_emit_write_barrier( $arr, $off, $vr );
                }
                else {
                    $builder->emit( 'store_mem_disp', 'void', [ $arr, $off, $vr ] );
                }
            }
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
                my ( $arg_reg, $arg_type ) = $self->lower($arg);
                if ($is_c_callback) {
                    push @processed_args, $builder->emit( 'shr', 'i64', [ $arg_reg, 1 ] );
                }
                else {
                    push @processed_args, $arg_reg;
                }
            }
            my $res = $builder->emit( 'call_reg', 'i64', [ $invocant_reg, @processed_args ] );
            if ($is_c_callback) {
                $res = $builder->emit( 'and', 'i64', [ $res, 0xFFFFFFFF ] );
                $res = $builder->emit( 'or',  'i64', [ $builder->emit( 'shl', 'i64', [ $res, 1 ] ), 1 ] );
            }
            return ( $res, 'Any' );
        }

        method lower_Eval($node) {
            my $code_node = $node->code;
            my $source;
            if ( $code_node isa Brocken::AST::Expr::Const && $code_node->type eq 'String' ) {
                $source = $code_node->value;
            } else {
                die "Cannot eval: only static string literals are supported at compile-time";
            }
            my $jit = Brocken::JIT->new( driver => $driver, arch => $driver->arch, os => $driver->os, standalone => 1 );
            my $run_result;
            my $compile_error;
            {
                local $@;
                eval { $run_result = $jit->compile_and_run($source) };
                $compile_error = $@;
            }
            if ($compile_error) { die "EVAL ERROR: $compile_error"; }
            return ( $builder->emit( 'constant', 'i64', [ $run_result // 0 ] ), 'Int' );
        }

        method lower_Use($node) { return $self->lower_Require($node); }

        method lower_Require($node) {
            my $package  = $node->package;
            my $filename = $package;
            $filename =~ s|::|/|g;
            $filename .= ".brocken";
            my $path;
            for my $dir ( '.', 'lib' ) {
                if ( -f "$dir/$filename" ) {
                    $path = "$dir/$filename";
                    last;
                }
            }
            die "Cannot find module $package ($filename)" unless $path;
            open my $fh, '<', $path or die "Cannot open $path: $!";
            my $source = do { local $/; <$fh> };
            close $fh;
            my $tokens = Brocken::Lexer->new( source => $source )->lex();
            my $ast    = Brocken::Parser->new( tokens => $tokens )->parse();

            $self->register_classes($ast);

            my @main_stmts;
            for my $n (@$ast) {
                if    ( $n isa Brocken::AST::OOP::Method )    { $self->lower($n); }
                elsif ( $n isa Brocken::AST::OOP::ClassDecl ) { $self->lower($n); }
                else                                          { push @main_stmts, $n; }
            }
            for my $stmt (@main_stmts) { $self->lower($stmt); }
            return ( $builder->emit( 'constant', 'i64', [1] ), 'Int' );
        }

        method lower_Method($node) {
            $driver->reset_locals(); @defer_stack=(); my $fn='M_'.$node->name; $builder->emit_label($fn);
            $builder->emit('enter_func', 'void', []);
            $current_scope=Brocken::Scope->new(parent=>$current_scope); $routine_depth++;
            my $ai=0;
            for my $p (@{$node->params}) {
                my $l=$driver->alloc_local_slot(); $current_scope->define($p->{name},$p->{type},0,undef,$l);
                $builder->emit('local_store', 'void', [$l,$builder->emit('get_arg','i64',[$ai++])])
            }
            $self->lower_block($node->body->statements); $self->_emit_all_defers();
            $builder->emit('leave_func', 'void', [0]);
            $routine_depth--; $current_scope=$current_scope->parent;
            push @exported_funcs, $node->name;
            $self->_generate_export_thunk($node);
            return (undef, 'void');
        }

        method lower_ClassDecl($node) {
            my $ci=$class_info{$node->name}; my $off=16; for my $f (@{$node->fields}){$off+=8}
            $driver->reset_locals();
            $builder->emit_label("M_".$node->name."::new"); $builder->emit('enter_func','void',[]);
            my $obj=$builder->emit('call_func','ptr',['M_gc_alloc',$builder->emit('constant','i64',[$off])]);
            $builder->emit('store_mem_disp','void',[$obj,0,$builder->emit('load_mem_disp', 'ptr', [$builder->emit('load_iso_disp','ptr',[16]),$ci->{id}*8])]);
            $builder->emit('store_mem_disp','void',[$obj,8,$builder->emit('constant','i64',[1])]); $builder->emit('leave_func','void',[$obj]);
            for my $m (@{$node->methods}){
                $driver->reset_locals(); @defer_stack=(); my $fn_name="M_".$node->name."::".$m->name; $builder->emit_label($fn_name); $builder->emit('enter_func','void',[]);
                $current_scope=Brocken::Scope->new(parent=>$current_scope); $routine_depth++;
                my $ss=$driver->alloc_local_slot(); $current_scope->define('$self','ptr',0,undef,$ss); $builder->emit('local_store','void',[$ss,$builder->emit('get_arg','ptr', [0])]);
                my $ai=1; my $fo=16; for my $field (@{$node->fields}){ $current_scope->define($field->name,'Any',0,undef,-$fo); $fo+=8 }
                for my $p (@{$m->params}){ my $l=$driver->alloc_local_slot(); $current_scope->define($p->{name},$p->{type},0,undef,$l); $builder->emit('local_store','void',[$l,$builder->emit('get_arg','i64',[$ai++])]) }
                $self->lower_block($m->body->statements); $self->_emit_all_defers(); $builder->emit('leave_func','void',[0]);
                $routine_depth--; $current_scope=$current_scope->parent;
            }
            return (undef,'void');
        }

        method lower_NativeDecl($node) {
            $native_funcs{$node->name} = { library => $node->library, signature => $node->signature };
            return (undef, 'void');
        }

        method register_classes($nodes) {
            for my $node (@$nodes){
                if($node isa Brocken::AST::OOP::ClassDecl){
                    my @mn; my @po; my $co=16;
                    for my $m (@{$node->methods}){ push @mn, $m->name; $global_methods{$m->name}//=$global_method_count++ }
                    for my $f (@{$node->fields}){ push @po,$co if $f->type=~/^(Any|String|Array|Fiber|Class)$/; $co+=8 }
                    $class_info{$node->name}={id=>$class_id_counter++, method_names=>\@mn, ptr_offsets=>\@po}
                }
            }
        }

        method lower_block($stmts) {
            my ($r,$t); for my $s (grep {defined} @$stmts){ ($r,$t)=$self->lower($s) } return ($r,$t)
        }
    }
}
1;
