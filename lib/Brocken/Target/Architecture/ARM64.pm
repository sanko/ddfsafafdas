use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';

class Brocken::Target::Architecture::ARM64 : isa(Brocken::Target) {

    method registers() {
        return [qw(x19 x20 x21 x22 x23 x24 x25 x26 x27)];
    }

    method fp_registers() {
        return [qw(d8 d9 d10 d11 d12 d13 d14 d15)];
    }

    method _abi_arg_reg($idx) {
        return (qw[x0 x1 x2 x3 x4 x5 x6 x7])[$idx] // $idx;
    }

    method _abi_fp_arg_reg($idx) {
        return (qw[d0 d1 d2 d3 d4 d5 d6 d7])[$idx] // "d$idx";
    }

    method _abi_fp_return_reg() {
        return 'd0';
    }

    method compile_intrinsic( $as, $inst, $reg_map, $driver ) {
        my $op    = $inst->{op};
        my $v     = sub { $self->val( $reg_map, shift ) };
        my $d_reg = $reg_map->{ $inst->{dest} } if $inst->{dest};
        if ( $op eq 'intrinsic_get_text_base' ) {
            $as->lea_rva( $d_reg, 0, $driver->text_rva );
            return;
        }
        return $driver->platform->emit_intrinsic( $self, $as, $inst, $reg_map, $driver );
    }

    method new_assembler() {
        return Brocken::Target::Architecture::ARM64::Emit->new();
    }

    method _compute_local_pos_offset( $driver, $slot ) {
        return $driver->frame_local_size - $slot;
    }

    method _move_val_to_scratch( $as, $v, $inst, $reg_map, $idx = 0 ) {
        my $arg = $inst->{args}[$idx];
        if    ( $arg =~ /^%/ )      { return $reg_map->{$arg}; }
        elsif ( $arg =~ /^[a-z]/i ) { $as->mov_reg( 'x16', $arg ); return 'x16'; }
        else                        { $as->mov_imm( 'x16', $v->($arg) ); return 'x16'; }
    }

    method emit_op( $as, $inst, $reg_map, $driver ) {
        my $op    = $inst->{op};
        my $v     = sub { $self->val( $reg_map, shift ) };
        my $d_reg = $reg_map->{ $inst->{dest} } if $inst->{dest};
        if    ( $op eq 'jmp' ) { $as->jmp( $inst->{target} ); }
        elsif ( $op eq 'cond_br' ) {
            my $reg = $v->( $inst->{reg} );
            $as->cmp_reg_imm( $reg, 0 );
            $as->jcc( $driver->cc('ne'), $inst->{true_l} );
            $as->jmp( $inst->{false_l} );
        }
        elsif ( $op eq 'constant' ) {
            $as->mov_imm( $d_reg, $inst->{args}[0] );
        }
        elsif ( $op eq 'mov' ) {
            my $src = $inst->{args}[0];
            if    ( $src =~ /^%/ )      { $as->mov_reg( $d_reg, $reg_map->{$src} ) if $d_reg ne $reg_map->{$src}; }
            elsif ( $src =~ /^[a-z]/i ) { $as->mov_reg( $d_reg, $src ) if $d_reg ne $src; }
            else                        { $as->mov_imm( $d_reg, $v->($src) ); }
        }
        elsif ( $op eq 'ret' ) {
            $as->ret();
        }
        elsif ( $op eq 'call_label' ) {
            $as->call_label( $inst->{target} );
        }
        elsif ( $op eq 'call_rva' ) {
            $as->call_rva( $inst->{target}, $driver->text_rva );
        }
        elsif ( $op eq 'label' ) {
            $as->mark_label( $inst->{name} );
        }

        # --- Function Prologue / Epilogue ---
        elsif ( $op eq 'enter_func' || $op eq 'enter_leaf_func' ) {
            for my $r ( @{ $driver->preserved_regs() } ) { $as->push_reg($r); }
            $as->mov_reg( 'x29', 'sp' );
            my $fsz = $driver->frame_local_size;
            if ( $fsz <= 4095 ) { $as->sub_imm( 'sp', $fsz ); }
            else {
                $as->mov_imm( 'x16', $fsz );
                $as->sub_reg( 'sp', 'sp', 'x16' );
            }
        }
        elsif ( $op eq 'push_frame' ) {
            for my $r ( @{ $driver->preserved_regs() } ) { $as->push_reg($r); }
            $as->mov_reg( 'x29', 'sp' );
            my $fsz = $driver->frame_local_size;
            if ( $fsz <= 4095 ) { $as->sub_imm( 'sp', $fsz ); }
            else {
                $as->mov_imm( 'x16', $fsz );
                $as->sub_reg( 'sp', 'sp', 'x16' );
            }
        }
        elsif ( $op eq 'load_isolate_ctx' ) {
            if ( defined $driver->global_iso_offset ) {
                $as->lea_rva( 'x16', "DATA:" . $driver->global_iso_offset );
                $as->load_reg_mem( 'x28', 'x16', 0 );
            }
        }
        elsif ( $op eq 'leave_func' ) {
            if ( defined $inst->{args}[0] ) {
                my $arg = $inst->{args}[0];
                if ( $arg =~ /^%/ ) { $as->mov_reg( 'x0', $reg_map->{$arg} ); }
                else                { $as->mov_imm( 'x0', $v->($arg) ); }
            }
            my $fsz = $driver->frame_local_size;
            if ( $fsz <= 4095 ) { $as->add_imm( 'sp', $fsz ); }
            else {
                $as->mov_imm( 'x16', $fsz );
                $as->add_reg( 'sp', 'sp', 'x16' );
            }
            for my $r ( reverse @{ $driver->preserved_regs() } ) { $as->pop_reg($r); }
            $as->ret();
        }

        # --- Local Load / Store (register spills & lower-level stack slots) ---
        elsif ( $op eq 'local_store' ) {
            my $slot = $inst->{args}[0];
            my $pos  = $self->_compute_local_pos_offset( $driver, $slot );
            my $src  = $self->_move_val_to_scratch( $as, $v, $inst, $reg_map, 1 );
            $as->store_mem_disp_reg( 'sp', $pos, $src );
        }
        elsif ( $op eq 'local_load' ) {
            my $slot = $inst->{args}[0];
            my $pos  = $self->_compute_local_pos_offset( $driver, $slot );
            $as->load_reg_mem( $d_reg, 'sp', $pos );
        }

        # --- Memory load/store with displacement ---
        elsif ( $op eq 'store_mem_disp' ) {
            my $base = $reg_map->{ $inst->{args}[0] };
            my $disp = $inst->{args}[1];
            my $src  = $self->_move_val_to_scratch( $as, $v, $inst, $reg_map, 2 );
            if ( $disp >= 0 && ( $disp & 7 ) == 0 && $disp <= 32760 ) {
                $as->store_mem_disp_reg( $base, $disp, $src );
            }
            else {
                if ( $disp >= 0 && $disp <= 4095 ) { $as->lea_reg_disp( 'x16', $base, $disp ); }
                else                               { $as->mov_imm( 'x16', $disp ); $as->add_reg( 'x16', 'x16', $base ); }
                $as->store_mem_disp_reg( 'x16', 0, $src );
            }
        }
        elsif ( $op eq 'load_mem_disp' ) {
            my $base = $reg_map->{ $inst->{args}[0] };
            my $disp = $inst->{args}[1];
            if ( $disp >= 0 && ( $disp & 7 ) == 0 && $disp <= 32760 ) {
                $as->load_reg_mem( $d_reg, $base, $disp );
            }
            else {
                $as->mov_imm( 'x16', $disp );
                $as->add_reg( 'x16', $base, 'x16' );
                $as->load_reg_mem( $d_reg, 'x16', 0 );
            }
        }
        elsif ( $op eq 'load_mem_byte' ) {
            my $base = $reg_map->{ $inst->{args}[0] };
            my $idx  = $inst->{args}[1];
            if ( $idx =~ /^%/ ) {
                $as->add_reg( 'x16', $base, $reg_map->{$idx} );
                $as->load_reg_mem_byte( $d_reg, 'x16', 0 );
            }
            else { $as->load_reg_mem_byte( $d_reg, $base, $v->($idx) ); }
        }
        elsif ( $op eq 'store_mem_byte' ) {
            my $base = $reg_map->{ $inst->{args}[0] };
            my $idx  = $inst->{args}[1];
            my $src  = $self->_move_val_to_scratch( $as, $v, $inst, $reg_map, 2 );
            if ( $idx =~ /^%/ ) {
                $as->add_reg( 'x16', $base, $reg_map->{$idx} );
                $as->store_mem_disp_byte( 'x16', 0, $src );
            }
            else { $as->store_mem_disp_byte( $base, $v->($idx), $src ); }
        }

        # --- Function Calls ---
        elsif ( $op =~ /^call_/ || $op =~ /^tail_call_/ ) {
            my @args   = @{ $inst->{args} };
            my $target = ( $op =~ /_func$/ ) ? shift @args : undef;
            if ( $op =~ /_reg$/ ) {
                my $first_arg = shift @args;
                my $src_reg   = ( $first_arg =~ /^%/ && exists $reg_map->{$first_arg} ) ? $reg_map->{$first_arg} : 'x16';
                $as->mov_reg( 'x16', $src_reg );
            }
            for my $i ( 0 .. $#args ) {
                my $dst = $self->_abi_arg_reg($i);
                my $arg = $args[$i];
                if    ( $arg =~ /^%/ )       { $as->mov_reg( $dst, $reg_map->{$arg} ) if $dst ne $reg_map->{$arg}; }
                elsif ( $arg =~ /^[A-Z_]/i ) { $as->lea_rva( 'x16', $arg, $driver->text_rva ); $as->mov_reg( $dst, 'x16' ) if $dst ne 'x16'; }
                else {
                    my $imm = $v->($arg);
                    if ( $imm == 0 ) { $as->mov_reg( $dst, 'xzr' ); }
                    else             { $as->mov_imm( $dst, $imm ); }
                }

                # Unconditionally mirror to FP registers
                if ( $i < 8 ) {
                    $as->fmov_x_to_d( "d$i", $dst );
                }
            }
            if ( $op =~ /^tail_call_/ ) {
                my $fsz = $driver->frame_local_size;
                if ( $fsz <= 4095 ) { $as->add_imm( 'sp', $fsz ); }
                else                { $as->mov_imm( 'x16', $fsz ); $as->add_reg( 'sp', 'sp', 'x16' ); }
                for my $r ( reverse @{ $driver->preserved_regs() } ) { $as->pop_reg($r); }
                if   ( $op eq 'tail_call_func' ) { $as->jmp($target); }
                else                             { $as->jmp_reg('x16'); }
            }
            else {
                if   ( $op eq 'call_func' ) { $as->call_label($target); }
                else                        { $as->append_code( pack( 'L<', 0xD63F0200 ) ); }    # blr x16
                if ( defined $d_reg ) {
                    if ( $inst->{type} &&
                        ( $inst->{type} eq 'double' || $inst->{type} eq 'float' || $inst->{type} eq 'Float' || $inst->{type} eq 'Double' ) ) {
                        $as->fmov_d_to_x( $d_reg, 'd0' );
                    }
                    else {
                        $as->mov_reg( $d_reg, 'x0' );
                    }
                }
            }
        }

        # --- Shadow Stack ---
        elsif ( $op eq 'shadow_push' ) {
            $as->load_reg_mem( 'x16', 'x28', $driver->iso_offset('current_fcb') );
            $as->load_reg_mem( 'x17', 'x16', $driver->fcb_offset('shadow_ptr') );
            my $src = $self->_move_val_to_scratch( $as, $v, $inst, $reg_map, 0 );
            $as->store_mem_disp_reg( 'x17', 0, $src );
            $as->add_imm( 'x17', 8 );
            $as->store_mem_disp_reg( 'x16', $driver->fcb_offset('shadow_ptr'), 'x17' );
        }
        elsif ( $op eq 'shadow_pop' ) {
            $as->load_reg_mem( 'x16', 'x28', $driver->iso_offset('current_fcb') );
            $as->load_reg_mem( 'x17', 'x16', $driver->fcb_offset('shadow_ptr') );
            $as->sub_imm( 'x17', 8 );
            $as->load_reg_mem( $d_reg, 'x17', 0 ) if defined $d_reg;
            $as->store_mem_disp_reg( 'x16', $driver->fcb_offset('shadow_ptr'), 'x17' );
        }
        elsif ( $op =~ /^shadow_(get|set|restore)$/ ) {
            $as->load_reg_mem( 'x16', 'x28', $driver->iso_offset('current_fcb') );
            if ( $op eq 'shadow_get' ) { $as->load_reg_mem( $d_reg, 'x16', $driver->fcb_offset('shadow_ptr') ); }
            else {
                my $src = $self->_move_val_to_scratch( $as, $v, $inst, $reg_map, 0 );
                $as->store_mem_disp_reg( 'x16', $driver->fcb_offset('shadow_ptr'), $src );
            }
        }

        # --- Stack Allocation ---
        elsif ( $op eq 'stack_alloc' ) {
            my $psz            = $inst->{args}[0];
            my $aligned_sz     = $inst->{args}[1];
            my $slot           = $inst->{slot};
            my $hdr_offset     = -$slot;
            my $payload_offset = -$slot + 8;
            my $fhdr           = $aligned_sz | ( $psz & 0xC000000000000000 );
            $as->mov_imm( 'x16', $fhdr );
            $as->store_mem_disp_reg( 'x29', $hdr_offset, 'x16' );

            for ( my $off = $payload_offset; $off < $hdr_offset + $aligned_sz; $off += 8 ) {
                $as->mov_imm( 'x16', 0 );
                $as->store_mem_disp_reg( 'x29', $off, 'x16' );
            }
            $as->lea_reg_disp( $d_reg, 'x29', $payload_offset );
        }

        # --- ALU (integer) ---
        elsif ( $op =~ /^(add|sub|mul|and|or|xor)$/ ) {
            my ( $l_raw, $r_raw ) = @{ $inst->{args} };
            my $l_reg = ( $l_raw =~ /^%/ ) ? $reg_map->{$l_raw} : 'x16';
            if    ( $l_raw !~ /^%/ && $l_raw !~ /^[a-z]/i ) { $as->mov_imm( 'x16', $v->($l_raw) ); }
            elsif ( $l_raw =~ /^[a-z]/i ) { $as->mov_reg( 'x16',  $l_raw ); $l_reg = 'x16'; }
            if    ( $l_reg ne $d_reg )    { $as->mov_reg( $d_reg, $l_reg ); }
            if    ( $r_raw =~ /^%/ ) {
                my $rr = $reg_map->{$r_raw};
                if    ( $op eq 'add' ) { $as->add_reg( $d_reg, $d_reg, $rr ); }
                elsif ( $op eq 'sub' ) { $as->sub_reg( $d_reg, $d_reg, $rr ); }
                elsif ( $op eq 'mul' ) { $as->mul_reg( $d_reg, $d_reg, $rr ); }
                elsif ( $op eq 'and' ) { $as->and_reg( $d_reg, $d_reg, $rr ); }
                elsif ( $op eq 'or' )  { $as->or_reg( $d_reg, $d_reg, $rr ); }
                elsif ( $op eq 'xor' ) { $as->xor_reg( $d_reg, $d_reg, $rr ); }
            }
            else {
                my $imm = $v->($r_raw);
                if    ( $op eq 'add' ) { $as->add_imm( $d_reg, $imm ); }
                elsif ( $op eq 'sub' ) { $as->sub_imm( $d_reg, $imm ); }
                else {
                    if    ( $imm > 4095 || $imm < 0 ) { $as->mov_imm( 'x16', $imm ); }
                    if    ( $op eq 'add' )            { $as->add_imm( $d_reg, $imm ); }
                    elsif ( $op eq 'sub' )            { $as->sub_imm( $d_reg, $imm ); }
                    elsif ( $op eq 'mul' )            { $as->mul_reg( $d_reg, $d_reg, 'x16' ); }
                    elsif ( $op eq 'and' )            { $as->and_reg( $d_reg, $d_reg, 'x16' ); }
                    elsif ( $op eq 'or' )             { $as->or_reg( $d_reg, $d_reg, 'x16' ); }
                    elsif ( $op eq 'xor' )            { $as->xor_reg( $d_reg, $d_reg, 'x16' ); }
                }
            }
        }

        # --- Division and Modulo ---
        elsif ( $op =~ /^(div|mod)$/ ) {
            my ( $l_raw, $r_raw ) = @{ $inst->{args} };
            my $l_reg = ( $l_raw =~ /^%/ ) ? $reg_map->{$l_raw} : 'x16';
            if ( $l_raw !~ /^%/ ) { $as->mov_imm( 'x16', $v->($l_raw) ); $l_reg = 'x16'; }
            $as->mov_reg( 'x16', $l_reg );
            if ( $r_raw =~ /^%/ ) { $as->sdiv_reg( 'x17', 'x16', $reg_map->{$r_raw} ); }
            else                  { $as->mov_imm( 'x17', $v->($r_raw) ); $as->sdiv_reg( 'x17', 'x16', 'x17' ); }
            if ( $op eq 'div' ) { $as->mov_reg( $d_reg, 'x17' ); }
            else {
                $as->mul_reg( 'x17', 'x17', ( $r_raw =~ /^%/ ? $reg_map->{$r_raw} : 'x17' ) );
                $as->sub_reg( $d_reg, 'x16', 'x17' );
            }
        }

        # --- Shifts ---
        elsif ( $op =~ /^(shl|shr)$/ ) {
            my ( $val_raw, $amt_raw ) = @{ $inst->{args} };
            my $val_reg = ( $val_raw =~ /^%/ ) ? $reg_map->{$val_raw} : 'x16';
            if ( $val_raw !~ /^%/ ) { $as->mov_imm( 'x16', $v->($val_raw) ); $val_reg = 'x16'; }
            $as->mov_reg( $d_reg, $val_reg ) if $d_reg ne $val_reg;
            if ( $amt_raw =~ /^%/ ) {
                my $ar = $reg_map->{$amt_raw};
                if ( $op eq 'shl' ) { $as->lslv_reg( $d_reg, $d_reg, $ar ); }
                else                { $as->lsrv_reg( $d_reg, $d_reg, $ar ); }
            }
            else {
                my $amt = $v->($amt_raw);
                if ( $op eq 'shl' ) { $as->lsl_imm( $d_reg, $d_reg, $amt ); }
                else                { $as->shr_imm( $d_reg, $d_reg, $amt ); }
            }
        }

        # --- Comparisons ---
        elsif ( $op =~ /^cmp_/ ) {
            my ( $l_raw, $r_raw ) = @{ $inst->{args} };
            my $l_reg = ( $l_raw =~ /^%/ ) ? $reg_map->{$l_raw} : 'x16';
            if ( $l_raw !~ /^%/ ) { $as->mov_imm( 'x16', $v->($l_raw) ); $l_reg = 'x16'; }
            if ( $r_raw =~ /^%/ ) { $as->cmp_reg_reg( $l_reg, $reg_map->{$r_raw} ); }
            else {
                my $imm = $v->($r_raw);
                if ( $imm > 4095 || $imm < 0 ) { $as->mov_imm( 'x17', $imm ); $as->cmp_reg_reg( $l_reg, 'x17' ); }
                else                           { $as->cmp_reg_imm( $l_reg, $imm ); }
            }
            my $cc = { eq => 0, ne => 1, lt => 0xB, gt => 0xC, le => 0xD, ge => 0xA }->{ substr( $op, 4 ) };
            $as->cset( $d_reg, $cc );
        }

        # --- Reference Counting ---
        elsif ( $op =~ /^(local|atomic)_(inc|dec)_ref$/ ) {
            my $is_atomic = $1 eq 'atomic';
            my $is_inc    = $2 eq 'inc';
            my $obj       = $reg_map->{ $inst->{args}[0] };
            my $rc_adj    = 1 << 48;
            if ($is_atomic) {

                # Use load-linked/store-conditional for atomic ref counting
                $as->ldxr_reg( 'x16', $obj );
                my $adj = $is_inc ? $rc_adj : -$rc_adj;
                $as->add_imm( 'x17', $obj, -8 );
                $as->add_reg( 'x16', 'x16', ( $is_inc ? 'x16' : 'x17' ) );
                $as->stxr_reg( 'x16', 'x16', 'x17' );
            }
            else {
                $as->mov_imm( 'x16', $rc_adj );
                if ($is_inc) {
                    $as->load_reg_mem( 'x17', $obj, -8 );
                    $as->add_reg( 'x16', 'x17', 'x16' );
                    $as->store_mem_disp_reg( $obj, -8, 'x16' );
                }
                else { $as->load_reg_mem( 'x17', $obj, -8 ); $as->sub_reg( 'x16', 'x17', 'x16' ); $as->store_mem_disp_reg( $obj, -8, 'x16' ); }
            }
        }

        # --- Isolate context access ---
        elsif ( $op eq 'load_iso_disp' ) { $as->load_reg_mem( $d_reg, 'x28', $inst->{args}[0] ); }
        elsif ( $op eq 'store_iso_disp' ) {
            my $src = $self->_move_val_to_scratch( $as, $v, $inst, $reg_map, 1 );
            $as->store_mem_disp_reg( 'x28', $inst->{args}[0], $src );
        }
        elsif ( $op =~ /^load_(func|data)_addr$/ ) {
            my $trva = $inst->{args}[0];
            if ( $trva =~ /^\d+$/ ) {
                if ( $op eq 'load_data_addr' ) { $as->lea_rva( $d_reg, "DATA:$trva" ); }
                else                           { $as->lea_rva( $d_reg, $trva, $driver->text_rva ); }
            }
            else { $as->lea_rva( $d_reg, $trva ); }
        }
        elsif ( $op eq 'get_isolate_ctx' ) { $as->mov_reg( $d_reg, 'x28' ); }
        elsif ( $op eq 'set_isolate_ctx' ) { $as->mov_reg( 'x28',  $reg_map->{ $inst->{args}[0] } ); }
        elsif ( $op eq 'get_arg' ) {
            my $arg_idx = $inst->{args}[0];
            $as->mov_reg( $d_reg, $self->_abi_arg_reg($arg_idx) );
        }
        elsif ( $op eq 'get_sp' ) { $as->mov_reg( $d_reg, 'sp' ); }
        elsif ( $op eq 'get_bp' ) { $as->mov_reg( $d_reg, 'x29' ); }
        elsif ( $op eq 'cvt_f32_f64' ) {
            my $src   = $inst->{args}[0];
            my $s_reg = ( $src =~ /^%/ ) ? $reg_map->{$src} : 'x16';
            if ( $src !~ /^%/ ) { $as->mov_imm( 'x16', $v->($src) ); }
            $as->fmov_x_to_d( 'd0', $s_reg );
            $as->fcvt_s_to_d( 'd0', 'd0' );
            $as->fmov_d_to_x( $d_reg, 'd0' );
        }
        elsif ( $op eq 'cvt_f64_f32' ) {
            my $src   = $inst->{args}[0];
            my $s_reg = ( $src =~ /^%/ ) ? $reg_map->{$src} : 'x16';
            if ( $src !~ /^%/ ) { $as->mov_imm( 'x16', $v->($src) ); }
            $as->fmov_x_to_d( 'd0', $s_reg );
            $as->fcvt_d_to_s( 'd0', 'd0' );
            $as->fmov_d_to_x( $d_reg, 'd0' );
        }
        elsif ( $op eq 'cvt_i64_f64' ) {
            my $src   = $inst->{args}[0];
            my $s_reg = ( $src =~ /^%/ ) ? $reg_map->{$src} : 'x16';
            if ( $src !~ /^%/ ) { $as->mov_imm( 'x16', $v->($src) ); }
            $as->scvtf_x_to_d( 'd0', $s_reg );
            $as->fmov_d_to_x( $d_reg, 'd0' );
        }
        elsif ( $op eq 'cvt_f64_i64' ) {
            my $src   = $inst->{args}[0];
            my $s_reg = ( $src =~ /^%/ ) ? $reg_map->{$src} : 'x16';
            if ( $src !~ /^%/ ) { $as->mov_imm( 'x16', $v->($src) ); }
            $as->fmov_x_to_d( 'd0', $s_reg );
            $as->fcvtzs_d_to_x( $d_reg, 'd0' );
        }
    }
}

class Brocken::Target::Architecture::ARM64::Emit {
    state $REG_MAP = {
        x0  => 0,
        x1  => 1,
        x2  => 2,
        x3  => 3,
        x4  => 4,
        x5  => 5,
        x6  => 6,
        x7  => 7,
        x8  => 8,
        x9  => 9,
        x10 => 10,
        x11 => 11,
        x12 => 12,
        x13 => 13,
        x14 => 14,
        x15 => 15,
        x16 => 16,
        x17 => 17,
        x18 => 18,
        x19 => 19,
        x20 => 20,
        x21 => 21,
        x22 => 22,
        x23 => 23,
        x24 => 24,
        x25 => 25,
        x26 => 26,
        x27 => 27,
        x28 => 28,
        x29 => 29,
        x30 => 30,
        sp  => 31,
        xzr => 31,
        rsp => 31,
        d0  => 0,
        d1  => 1,
        d2  => 2,
        d3  => 3,
        d4  => 4,
        d5  => 5,
        d6  => 6,
        d7  => 7,
        d8  => 8,
        d9  => 9,
        d10 => 10,
        d11 => 11,
        d12 => 12,
        d13 => 13,
        d14 => 14,
        d15 => 15,
        rax => 0,
        rcx => 1,
        rdx => 2,
        rbx => 3,
        rsi => 6,
        rdi => 7,
        r8  => 8,
        r9  => 9,
        r10 => 10,
        r11 => 11,
        r14 => 28,
        w0  => 0,
        w1  => 1,
        w2  => 2,
        w3  => 3,
        w4  => 4,
        w5  => 5,
        w6  => 6,
        w7  => 7,
        w8  => 8,
        w9  => 9,
        w10 => 10,
        w11 => 11,
        w12 => 12,
        w13 => 13,
        w14 => 14,
        w15 => 15,
        w16 => 16,
        w17 => 17,
        w18 => 18,
        w19 => 19,
        w20 => 20,
        w21 => 21,
        w22 => 22,
        w23 => 23,
        w24 => 24,
        w25 => 25,
        w26 => 26,
        w27 => 27,
        w28 => 28,
        w29 => 29,
        w30 => 30,
        wzr => 31
    };
    field $code : reader = '';
    field %labels;
    field @fixups;
    method labels() { return \%labels; }

    method reg($r) {
        my $name = lc( $r // '' );
        die "Unknown ARM64 register: $r" unless exists $REG_MAP->{$name};
        return $REG_MAP->{$name};
    }
    method label($key)        { $labels{$key} // () }
    method ret ()             { $code .= pack( 'L<', 0xD65F03C0 ) }
    method append_code ($bin) { $code .= $bin }

    method mov_imm ( $reg, $imm ) {
        my $r = $self->reg($reg);
        $code .= pack( 'L<', 0xD2800000 | ( ( $imm & 0xFFFF ) << 5 ) | $r );
        if ( ( $imm >> 16 ) & 0xFFFF ) {
            $code .= pack( 'L<', 0xF2A00000 | ( 1 << 21 ) | ( ( ( $imm >> 16 ) & 0xFFFF ) << 5 ) | $r );
        }
        if ( ( $imm >> 32 ) & 0xFFFF ) {
            $code .= pack( 'L<', 0xF2C00000 | ( 2 << 21 ) | ( ( ( $imm >> 32 ) & 0xFFFF ) << 5 ) | $r );
        }
        if ( ( $imm >> 48 ) & 0xFFFF ) {
            $code .= pack( 'L<', 0xF2E00000 | ( 3 << 21 ) | ( ( ( $imm >> 48 ) & 0xFFFF ) << 5 ) | $r );
        }
    }

    method mov_reg ( $dest, $src ) {
        my $d = $self->reg($dest);
        my $s = $self->reg($src);
        $code .= pack( 'L<', 0xAA0003E0 | ( $s << 16 ) | $d );
    }
    method push_reg($reg) { my $r = $self->reg($reg); $code .= pack( 'L<', 0xF81F0FE0 | $r ); }
    method pop_reg($reg)  { my $r = $self->reg($reg); $code .= pack( 'L<', 0xF84107E0 | $r ); }

    method add_imm ( $reg, $imm ) {
        my $r = $self->reg($reg);
        $code .= pack( 'L<', 0x91000000 | ( ( $imm & 0xFFF ) << 10 ) | ( $r << 5 ) | $r );
    }

    method sub_imm ( $reg, $imm ) {
        my $r = $self->reg($reg);
        $code .= pack( 'L<', 0xD1000000 | ( ( $imm & 0xFFF ) << 10 ) | ( $r << 5 ) | $r );
    }

    method add_reg ( $d, $s1, $s2 = undef ) {
        my $rd  = $self->reg($d);
        my $rs1 = $self->reg($s1);
        my $rs2 = defined $s2 ? $self->reg($s2) : $rd;
        $code .= pack( 'L<', 0x8B000000 | ( $rs2 << 16 ) | ( $rs1 << 5 ) | $rd );
    }

    method sub_reg ( $d, $s1, $s2 = undef ) {
        my $rd  = $self->reg($d);
        my $rs1 = $self->reg($s1);
        my $rs2 = defined $s2 ? $self->reg($s2) : $rd;
        $code .= pack( 'L<', 0xCB000000 | ( $rs2 << 16 ) | ( $rs1 << 5 ) | $rd );
    }

    method mul_reg ( $d, $s1, $s2 = undef ) {
        my $rd  = $self->reg($d);
        my $rs1 = $self->reg($s1);
        my $rs2 = defined $s2 ? $self->reg($s2) : $rd;
        $code .= pack( 'L<', 0x9B007C00 | ( $rs2 << 16 ) | ( $rs1 << 5 ) | $rd );
    }

    method sdiv_reg ( $d, $s1, $s2 = undef ) {
        my $rd  = $self->reg($d);
        my $rs1 = $self->reg($s1);
        my $rs2 = defined $s2 ? $self->reg($s2) : $rd;
        $code .= pack( 'L<', 0x9AC00C00 | ( $rs2 << 16 ) | ( $rs1 << 5 ) | $rd );
    }

    method and_reg ( $d, $s1, $s2 = undef ) {
        my $rd  = $self->reg($d);
        my $rs1 = $self->reg($s1);
        my $rs2 = defined $s2 ? $self->reg($s2) : $rd;
        $code .= pack( 'L<', 0x8A000000 | ( $rs2 << 16 ) | ( $rs1 << 5 ) | $rd );
    }

    method or_reg ( $d, $s1, $s2 = undef ) {
        my $rd  = $self->reg($d);
        my $rs1 = $self->reg($s1);
        my $rs2 = defined $s2 ? $self->reg($s2) : $rd;
        $code .= pack( 'L<', 0xAA000000 | ( $rs2 << 16 ) | ( $rs1 << 5 ) | $rd );
    }

    method xor_reg ( $d, $s1, $s2 = undef ) {
        my $rd  = $self->reg($d);
        my $rs1 = $self->reg($s1);
        my $rs2 = defined $s2 ? $self->reg($s2) : $rd;
        $code .= pack( 'L<', 0xCA000000 | ( $rs2 << 16 ) | ( $rs1 << 5 ) | $rd );
    }

    method lsl_imm ( $d, $s, $amt ) {
        my $rd = $self->reg($d);
        my $rs = $self->reg($s);
        $code .= pack( 'L<', 0xD3400000 | ( ( 64 - $amt ) << 16 ) | ( ( 63 - $amt ) << 10 ) | ( $rs << 5 ) | $rd );
    }

    method lsr_imm ( $d, $s, $amt ) {
        my $rd = $self->reg($d);
        my $rs = $self->reg($s);
        $code .= pack( 'L<', 0xD3400000 | ( $amt << 16 ) | ( 63 << 10 ) | ( $rs << 5 ) | $rd );
    }

    method shr_imm ( $d, $s, $amt = undef ) {
        if ( !defined $amt ) { $amt = $s; $s = $d }
        $self->lsr_imm( $d, $s, $amt );
    }
    method lsr_reg_imm ( $d, $s, $amt ) { $self->lsr_imm( $d, $s, $amt ) }

    method cmp_reg_imm ( $reg, $imm ) {
        my $r = $self->reg($reg);
        $code .= pack( 'L<', 0xF1000000 | ( ( $imm & 0xFFF ) << 10 ) | ( $r << 5 ) | 31 );
    }
    method cmp_reg_imm_32 ( $r, $imm ) { $self->cmp_reg_imm( $r, $imm ) }

    method cmp_reg_reg ( $l, $r ) {
        my $rl = $self->reg($l);
        my $rr = $self->reg($r);
        $code .= pack( 'L<', 0xEB000000 | ( $rr << 16 ) | ( $rl << 5 ) | 31 );
    }

    method test_reg_reg ( $l, $r ) {
        my $rl = $self->reg($l);
        my $rr = $self->reg($r);
        $code .= pack( 'L<', 0xEA000000 | ( $rr << 16 ) | ( $rl << 5 ) | 31 );
    }

    method setcc ( $cc, $r ) {
        my $ri = $self->reg($r);
        $code .= pack( 'L<', 0x1A9F07E0 | ( $cc << 12 ) | $ri );
    }

    method load_reg_mem( $dest, $src, $disp = 0 ) {
        my $d = $self->reg($dest);
        my $s = $self->reg($src);
        $code .= pack( 'L<', 0xF9400000 | ( ( $disp >> 3 ) << 10 ) | ( $s << 5 ) | $d );
    }

    method ldur_reg_mem( $dest, $src, $disp = 0 ) {
        my $d = $self->reg($dest);
        my $s = $self->reg($src);
        $code .= pack( 'L<', 0xF8400000 | ( ( $disp & 0x1FF ) << 12 ) | ( $s << 5 ) | $d );
    }

    method ldxr_reg ( $t, $n ) {
        my $rt = $self->reg($t);
        my $rn = $self->reg($n);
        $code .= pack( 'L<', 0xC85F7C00 | ( $rn << 5 ) | $rt );
    }

    method stxr_reg ( $s, $t, $n ) {
        my $rs = $self->reg($s);
        my $rt = $self->reg($t);
        my $rn = $self->reg($n);
        $code .= pack( 'L<', 0xC8007C00 | ( $rn << 5 ) | ( $rs << 16 ) | $rt );
    }

    method load_reg_mem_byte( $dest, $src, $disp = 0 ) {
        my $d = $self->reg($dest);
        my $s = $self->reg($src);
        $code .= pack( 'L<', 0x39400000 | ( $disp << 10 ) | ( $s << 5 ) | $d );
    }

    method store_mem_disp_reg( $base, $disp, $src ) {
        my $b = $self->reg($base);
        my $s = $self->reg($src);
        $code .= pack( 'L<', 0xF9000000 | ( ( $disp >> 3 ) << 10 ) | ( $b << 5 ) | $s );
    }

    method stur_mem_disp_reg( $base, $disp, $src ) {
        my $b = $self->reg($base);
        my $s = $self->reg($src);
        $code .= pack( 'L<', 0xF8000000 | ( ( $disp & 0x1FF ) << 12 ) | ( $b << 5 ) | $s );
    }

    method sturb_mem_disp_reg( $base, $disp, $src ) {
        my $b = $self->reg($base);
        my $s = $self->reg($src);
        $code .= pack( 'L<', 0x38000000 | ( ( $disp & 0x1FF ) << 12 ) | ( $b << 5 ) | $s );
    }

    method store_mem_disp_byte( $base, $disp, $src ) {
        my $b = $self->reg($base);
        my $s = $self->reg($src);
        $code .= pack( 'L<', 0x39000000 | ( $disp << 10 ) | ( $b << 5 ) | $s );
    }

    method lea_reg_disp ( $d, $b, $disp ) {
        my $rd = $self->reg($d);
        my $rb = $self->reg($b);
        $code .= pack( 'L<', 0x91000000 | ( ( $disp & 0xFFF ) << 10 ) | ( $rb << 5 ) | $rd );
    }

    method inc_byte_data($data_offset) {
        $self->lea_rva( 'x9', "DATA:$data_offset" );
        $self->load_reg_mem_byte( 'w8', 'x9' );
        $self->add_imm( 'x8', 1 );
        $self->store_mem_disp_byte( 'x9', 0, 'w8' );
    }

    method lea_rva ( $reg, $target_rva, $text_rva = 0 ) {
        my $r = $self->reg($reg);
        if ( $target_rva =~ /^DATA:(\d+)$/ ) {
            push @fixups, { offset => length($code), target => $1, type => 'adrp_data', reg => $r };
            $code .= pack( 'L<', 0x90000000 | $r );
            $code .= pack( 'L<', 0x91000000 | ( $r << 5 ) | $r );
            return;
        }
        my $off = ( $target_rva =~ /^\d+$/ ) ? $target_rva - ( $text_rva + length($code) ) : 0;
        push @fixups, { offset => length($code), target => $target_rva, type => 'adr', reg => $r } if $target_rva !~ /^\d+$/;
        my $immlo = $off & 0x3;
        my $immhi = ( $off >> 2 ) & 0x7FFFF;
        $code .= pack( 'L<', 0x10000000 | ( $immlo << 29 ) | ( $immhi << 5 ) | $r );
    }

    method call_rva ( $target_rva, $text_rva ) {
        $self->lea_rva( 'x16', $target_rva, $text_rva );
        $code .= pack( 'L<', 0xF9400000 | ( 16 << 5 ) | 16 );
        $code .= pack( 'L<', 0xD63F0200 );
    }

    method call_label ($label) {
        push @fixups, { offset => length($code), target => $label, type => 'call' };
        $code .= pack( 'L<', 0x94000000 );
    }

    method cbnz_label ( $reg, $label ) {
        my $ri = $self->reg($reg);
        push @fixups, { offset => length($code), target => $label, type => 'cbnz', reg => $ri };
        $code .= pack( 'L<', 0xB5000000 | $ri );
    }

    method syscall( $os = '', $num = 0 ) {
        if    ( $os eq 'macos' )              { $code .= pack( 'L<', 0xD4001001 ) }
        elsif ( $os eq 'netbsd' && $num > 0 ) { $code .= pack( 'L<', 0xD4000001 | ( ( $num & 0xFFFF ) << 5 ) ) }
        else {
            $code .= pack( 'L<', 0xD4000001 );
            if ( $os eq 'openbsd' ) { $code .= pack( 'L<', 0x14000002 ) . pack( 'L<', 0xD4200000 ) }
        }
    }

    method jcc ( $cc, $label ) {
        push @fixups, { offset => length($code), target => $label, type => 'cond', cc => $cc };
        $code .= pack( 'L<', 0x54000000 | $cc );
    }

    method jmp ($label) {
        push @fixups, { offset => length($code), target => $label, type => 'uncond' };
        $code .= pack( 'L<', 0x14000000 );
    }
    method mark_label ($name) { $labels{$name} = length $code }

    method fadd_reg ( $d, $s1, $s2 ) {
        my ( $rd, $rs1, $rs2 ) = ( $self->reg($d), $self->reg($s1), $self->reg($s2) );
        $code .= pack( 'L<', 0x1E602800 | ( $rs2 << 16 ) | ( $rs1 << 5 ) | $rd );
    }

    method fsub_reg ( $d, $s1, $s2 ) {
        my ( $rd, $rs1, $rs2 ) = ( $self->reg($d), $self->reg($s1), $self->reg($s2) );
        $code .= pack( 'L<', 0x1E603800 | ( $rs2 << 16 ) | ( $rs1 << 5 ) | $rd );
    }

    method fmul_reg ( $d, $s1, $s2 ) {
        my ( $rd, $rs1, $rs2 ) = ( $self->reg($d), $self->reg($s1), $self->reg($s2) );
        $code .= pack( 'L<', 0x1E600800 | ( $rs2 << 16 ) | ( $rs1 << 5 ) | $rd );
    }

    method fmov_reg ( $d, $s ) {
        my ( $rd, $rs ) = ( $self->reg($d), $self->reg($s) );
        $code .= pack( 'L<', 0x1E604000 | ( $rs << 5 ) | $rd );
    }

    method fcmp_reg ( $l, $r ) {
        my ( $rl, $rr ) = ( $self->reg($l), $self->reg($r) );
        $code .= pack( 'L<', 0x1E602000 | ( $rr << 16 ) | ( $rl << 5 ) );
    }

    method fcvt_s_to_d ( $d, $s ) {
        my ( $rd, $rs ) = ( $self->reg($d), $self->reg($s) );
        $code .= pack( 'L<', 0x1E22C000 | ( $rs << 5 ) | $rd );
    }

    method fcvt_d_to_s ( $d, $s ) {
        my ( $rd, $rs ) = ( $self->reg($d), $self->reg($s) );
        $code .= pack( 'L<', 0x1E624000 | ( $rs << 5 ) | $rd );
    }

    method scvtf_x_to_d ( $d, $s ) {
        my ( $rd, $rs ) = ( $self->reg($d), $self->reg($s) );
        $code .= pack( 'L<', 0x9E620000 | ( $rs << 5 ) | $rd );
    }

    method fcvtzs_d_to_x ( $d, $s ) {
        my ( $rd, $rs ) = ( $self->reg($d), $self->reg($s) );
        $code .= pack( 'L<', 0x9E780000 | ( $rs << 5 ) | $rd );
    }

    method fmov_x_to_d ( $d, $s ) {
        my ( $rd, $rs ) = ( $self->reg($d), $self->reg($s) );
        $code .= pack( 'L<', 0x9E670000 | ( $rs << 5 ) | $rd );
    }

    method fmov_d_to_x ( $d, $s ) {
        my ( $rd, $rs ) = ( $self->reg($d), $self->reg($s) );
        $code .= pack( 'L<', 0x9E660000 | ( $rs << 5 ) | $rd );
    }

    method ldr_d_mem ( $d, $s, $off ) {
        my ( $rd, $rs ) = ( $self->reg($d), $self->reg($s) );
        $code .= pack( 'L<', 0xFD400000 | ( ( $off >> 3 ) << 10 ) | ( $rs << 5 ) | $rd );
    }

    method str_d_mem ( $d, $s, $off ) {
        my ( $rd, $rs ) = ( $self->reg($d), $self->reg($s) );
        $code .= pack( 'L<', 0xFD000000 | ( ( $off >> 3 ) << 10 ) | ( $rs << 5 ) | $rd );
    }

    method cset( $reg, $cond ) {
        my $r = $self->reg($reg);
        $code .= pack( 'L<', 0x9A9F07E0 | ( $cond << 12 ) | $r );
    }

    method jmp_reg($reg) {
        my $r = $self->reg($reg);
        $code .= pack( 'L<', 0xD61F0000 | ( $r << 5 ) );
    }

    method lslv_reg( $d, $n, $m ) {
        my ( $rd, $rn, $rm ) = ( $self->reg($d), $self->reg($n), $self->reg($m) );
        $code .= pack( 'L<', 0xDA802800 | ( $rm << 16 ) | ( $rn << 5 ) | $rd );
    }

    method lsrv_reg( $d, $n, $m ) {
        my ( $rd, $rn, $rm ) = ( $self->reg($d), $self->reg($n), $self->reg($m) );
        $code .= pack( 'L<', 0xDA802C00 | ( $rm << 16 ) | ( $rn << 5 ) | $rd );
    }

    method resolve ( $text_rva, $data_rva ) {
        for (@fixups) {
            my $target_off;
            if ( $_->{type} ne 'adrp_data' ) {
                $target_off = $labels{ $_->{target} }
                    // ( ( $_->{type} eq 'adr' && $_->{target} =~ /^\d+$/ ) ? undef : die "Undefined label: $_->{target}" );
            }
            if ( $_->{type} eq 'cond' ) {
                my $off   = ( $target_off - $_->{offset} ) / 4;
                my $instr = unpack( 'L<', substr( $code, $_->{offset}, 4 ) );
                $instr |= ( $off & 0x7FFFF ) << 5;
                substr( $code, $_->{offset}, 4, pack( 'L<', $instr ) );
            }
            elsif ( $_->{type} eq 'call' || $_->{type} eq 'uncond' ) {
                my $off   = ( $target_off - $_->{offset} ) / 4;
                my $instr = unpack( 'L<', substr( $code, $_->{offset}, 4 ) );
                $instr |= ( $off & 0x3FFFFFF );
                substr( $code, $_->{offset}, 4, pack( 'L<', $instr ) );
            }
            elsif ( $_->{type} eq 'cbnz' ) {
                my $off   = ( $target_off - $_->{offset} ) / 4;
                my $instr = unpack( 'L<', substr( $code, $_->{offset}, 4 ) );
                $instr |= ( $off & 0x7FFFF ) << 5;
                substr( $code, $_->{offset}, 4, pack( 'L<', $instr ) );
            }
            elsif ( $_->{type} eq 'adr' ) {
                my $off   = ( $target_off - $_->{offset} );
                my $instr = unpack( 'L<', substr( $code, $_->{offset}, 4 ) );
                $instr |= ( ( $off & 0x3 ) << 29 ) | ( ( ( $off >> 2 ) & 0x7FFFF ) << 5 );
                substr( $code, $_->{offset}, 4, pack( 'L<', $instr ) );
            }
            elsif ( $_->{type} eq 'adrp_data' ) {
                my $trva   = $data_rva + $_->{target};
                my $pc     = $text_rva + $_->{offset};
                my $p_diff = ( $trva & ~0xFFF ) - ( $pc & ~0xFFF );
                my $imm    = $p_diff >> 12;
                my $instr  = unpack( 'L<', substr( $code, $_->{offset}, 4 ) );
                $instr |= ( ( $imm & 0x3 ) << 29 ) | ( ( $imm & 0x1FFFFC ) << 3 );
                substr( $code, $_->{offset}, 4, pack( 'L<', $instr ) );
                my $instr2 = unpack( 'L<', substr( $code, $_->{offset} + 4, 4 ) );
                $instr2 |= ( $trva & 0xFFF ) << 10;
                substr( $code, $_->{offset} + 4, 4, pack( 'L<', $instr2 ) );
            }
        }
    }
}
1;
