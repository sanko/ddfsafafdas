use v5.40;
use feature 'class';
no warnings 'experimental::class';

class Brocken::Target::ARM64 : isa(Brocken::Target) {

    method registers() {

        # Callee-saved registers x19-x27 (x28 reserved for isolate context)
        return [qw(x19 x20 x21 x22 x23 x24 x25 x26 x27)];
    }

    method fp_registers() {
        return [qw(d8 d9 d10 d11 d12 d13 d14 d15)];
    }

    method _abi_arg_reg($idx) {
        return (qw[x0 x1 x2 x3 x4 x5 x6 x7])[$idx] // 'stack';
    }

    method _abi_fp_arg_reg($idx) {
        return (qw[d0 d1 d2 d3 d4 d5 d6 d7])[$idx] // "d$idx";
    }

    method _abi_fp_return_reg() {
        return 'd0';
    }

    method emit_op( $as, $inst, $reg_map, $driver ) {
        my $op       = $inst->{op};
        my $v        = sub { $self->val( $reg_map, shift ) };
        my $d_reg    = $reg_map->{ $inst->{dest} } if $inst->{dest};
        my $is_float = ( $inst->{type} && ( $inst->{type} eq 'double' || $inst->{type} eq 'float' ) );
        if    ( $op eq 'jmp' ) { $as->jmp( $inst->{target} ); }
        elsif ( $op eq 'cond_br' ) {
            my $reg = $v->( $inst->{reg} );
            $as->test_reg_reg( $reg, $reg );
            $as->jcc( $driver->cc('nz'), $inst->{true_l} );
            $as->jmp( $inst->{false_l} );
        }
        elsif ( $op eq 'constant' ) {
            if ($is_float) {
                my $bits = unpack( 'Q<', pack( 'd<', $inst->{args}[0] ) );
                $as->mov_imm( 'x16', $bits );
                $as->fmov_x_to_d( $d_reg, 'x16' );
            }
            else {
                $as->mov_imm( $d_reg, $inst->{args}[0] );
            }
        }
        elsif ( $op eq 'mov' ) {
            my $s = $v->( $inst->{args}[0] );
            if ( $inst->{args}[0] =~ /^%/ || $inst->{args}[0] =~ /^[a-z]/i ) { $as->mov_reg( $d_reg, $s ) if ( $d_reg // '' ) ne ( $s // '' ); }
            else                                                             { $as->mov_imm( $d_reg, $s ); }
        }
        elsif ( $op =~ /^(add|sub|mul)$/ ) {
            my $lv = $v->( $inst->{args}[0] );
            my $rv = $v->( $inst->{args}[1] );
            if ($is_float) {
                my $ln = $lv;
                if ( $inst->{args}[0] !~ /^%/ ) {
                    my $bits = unpack( 'Q<', pack( 'd<', $lv ) );
                    $as->mov_imm( 'x16', $bits );
                    $as->fmov_x_to_d( 'd16', 'x16' );
                    $ln = 'd16';
                }
                my $rs = $rv;
                if ( $inst->{args}[1] !~ /^%/ ) {
                    my $bits = unpack( 'Q<', pack( 'd<', $rv ) );
                    $as->mov_imm( 'x16', $bits );
                    $as->fmov_x_to_d( 'd17', 'x16' );
                    $rs = 'd17';
                }
                if    ( $op eq 'add' ) { $as->fadd_reg( $d_reg, $ln, $rs ); }
                elsif ( $op eq 'sub' ) { $as->fsub_reg( $d_reg, $ln, $rs ); }
                elsif ( $op eq 'mul' ) { $as->fmul_reg( $d_reg, $ln, $rs ); }
                return;
            }
            my $ln = ( $inst->{args}[0] =~ /^%/ ) ? $lv : 'x16';
            $as->mov_imm( 'x16', $lv ) if $inst->{args}[0] !~ /^%/;
            if ( $inst->{args}[1] =~ /^%/ ) {
                my $rs = $reg_map->{ $inst->{args}[1] };
                if    ( $op eq 'add' ) { $as->add_reg( $d_reg, $ln, $rs ); }
                elsif ( $op eq 'sub' ) { $as->sub_reg( $d_reg, $ln, $rs ); }
                else                   { $as->mul_reg( $d_reg, $ln, $rs ); }
            }
            else {
                if ( $op eq 'add' ) {
                    if ( $rv >= 0 && $rv <= 0xFFF ) {
                        $as->mov_reg( $d_reg, $ln ) if $d_reg ne $ln;
                        $as->add_imm( $d_reg, $rv );
                    }
                    else {
                        $as->mov_imm( 'x17', $rv );
                        $as->add_reg( $d_reg, $ln, 'x17' );
                    }
                }
                elsif ( $op eq 'sub' ) {
                    if ( $rv >= 0 && $rv <= 0xFFF ) {
                        $as->mov_reg( $d_reg, $ln ) if $d_reg ne $ln;
                        $as->sub_imm( $d_reg, $rv );
                    }
                    else {
                        $as->mov_imm( 'x17', $rv );
                        $as->sub_reg( $d_reg, $ln, 'x17' );
                    }
                }
                else {
                    $as->mov_imm( 'x17', $rv );
                    $as->mul_reg( $d_reg, $ln, 'x17' );
                }
            }
        }
        elsif ( $op =~ /^(div|mod)$/ ) {
            my $lv = $v->( $inst->{args}[0] );
            my $rv = $v->( $inst->{args}[1] );
            if ($is_float) {
                my $ln = $lv;
                if ( $inst->{args}[0] !~ /^%/ ) {
                    my $bits = unpack( 'Q<', pack( 'd<', $lv ) );
                    $as->mov_imm( 'x16', $bits );
                    $as->fmov_x_to_d( 'd16', 'x16' );
                    $ln = 'd16';
                }
                my $rs = $rv;
                if ( $inst->{args}[1] !~ /^%/ ) {
                    my $bits = unpack( 'Q<', pack( 'd<', $rv ) );
                    $as->mov_imm( 'x16', $bits );
                    $as->fmov_x_to_d( 'd17', 'x16' );
                    $rs = 'd17';
                }
                $as->fdiv_reg( $d_reg, $ln, $rs );
                return;
            }
            my $ln = ( $inst->{args}[0] =~ /^%/ ) ? $lv : 'x16';
            $as->mov_imm( 'x16', $lv ) if $inst->{args}[0] !~ /^%/;
            my $rs = ( $inst->{args}[1] =~ /^%/ ) ? $reg_map->{ $inst->{args}[1] } : 'x17';
            $as->mov_imm( 'x17', $rv ) if $inst->{args}[1] !~ /^%/;
            if ( $op eq 'div' ) {
                $as->sdiv_reg( $d_reg, $ln, $rs );
            }
            else {
                $as->mov_reg( 'x15', $ln );
                $as->sdiv_reg( 'x16', $ln, $rs );
                $as->msub_reg( $d_reg, 'x16', $rs, 'x15' );
            }
        }
        elsif ( $op =~ /^(and|or|xor)$/ ) {
            my $lv = $v->( $inst->{args}[0] );
            my $rv = $v->( $inst->{args}[1] );
            my $ln = ( $inst->{args}[0] =~ /^%/ ) ? $lv : 'x16';
            $as->mov_imm( 'x16', $lv ) if $inst->{args}[0] !~ /^%/;
            if ( $inst->{args}[1] =~ /^%/ ) {
                my $rs = $reg_map->{ $inst->{args}[1] };
                if    ( $op eq 'and' ) { $as->and_reg( $d_reg, $ln, $rs ); }
                elsif ( $op eq 'or' )  { $as->or_reg( $d_reg, $ln, $rs ); }
                else                   { $as->xor_reg( $d_reg, $ln, $rs ); }
            }
            else {
                # ARM64 logical immediates are complex.
                # For simplicity, move to scratch register.
                $as->mov_imm( 'x17', $rv );
                if    ( $op eq 'and' ) { $as->and_reg( $d_reg, $ln, 'x17' ); }
                elsif ( $op eq 'or' )  { $as->or_reg( $d_reg, $ln, 'x17' ); }
                else                   { $as->xor_reg( $d_reg, $ln, 'x17' ); }
            }
        }
        elsif ( $op =~ /^cmp_(eq|ne|lt|gt|le|ge)$/ ) {
            my $type = $1;
            my $lv   = $v->( $inst->{args}[0] );
            my $rv   = $v->( $inst->{args}[1] );
            if ($is_float) {
                my $ln = $lv;
                if ( $inst->{args}[0] !~ /^%/ ) {
                    my $bits = unpack( 'Q<', pack( 'd<', $lv ) );
                    $as->mov_imm( 'x16', $bits );
                    $as->fmov_x_to_d( 'd16', 'x16' );
                    $ln = 'd16';
                }
                my $rs = $rv;
                if ( $inst->{args}[1] !~ /^%/ ) {
                    my $bits = unpack( 'Q<', pack( 'd<', $rv ) );
                    $as->mov_imm( 'x16', $bits );
                    $as->fmov_x_to_d( 'd17', 'x16' );
                    $rs = 'd17';
                }
                $as->fcmp_reg( $ln, $rs );
                $as->setcc( $driver->cc($type), $d_reg );
            }
            else {
                my $ln = ( $inst->{args}[0] =~ /^%/ ) ? $lv : 'x16';
                $as->mov_imm( 'x16', $lv ) if $inst->{args}[0] !~ /^%/;
                $inst->{args}[1] =~ /^%/ ? $as->cmp_reg_reg( $ln, $reg_map->{ $inst->{args}[1] } ) : $as->cmp_reg_imm( $ln, $rv );
                $as->setcc( $driver->cc($type), $d_reg );
            }
        }
        elsif ( $op =~ /^(shl|shr)$/ ) {
            my $val = $v->( $inst->{args}[0] );
            my $amt = $inst->{args}[1];
            my $ln  = ( $inst->{args}[0] =~ /^%/ ) ? $val : 'x16';
            $as->mov_imm( 'x16', $val ) if $inst->{args}[0] !~ /^%/;
            if ( $amt !~ /^%/ ) {
                if ( $op eq 'shl' ) { $as->lsl_imm( $d_reg, $ln, $v->($amt) ); }
                else                { $as->lsr_imm( $d_reg, $ln, $v->($amt) ); }
            }
            else {
                $as->mov_reg( 'x17', $reg_map->{$amt} );
                if ( $op eq 'shl' ) { $as->lsl_reg( $d_reg, $ln, 'x17' ); }
                else                { $as->lsr_reg( $d_reg, $ln, 'x17' ); }
            }
        }
        elsif ( $op eq 'local_store' ) {
            my $val = $v->( $inst->{args}[1] );
            my $src = ( $inst->{args}[1] =~ /^%/ ) ? $reg_map->{ $inst->{args}[1] } : 'x16';
            my $off = -$inst->{args}[0];
            if ($is_float) {
                if ( $inst->{args}[1] !~ /^%/ ) {
                    my $bits = unpack( 'Q<', pack( 'd<', $val ) );
                    $as->mov_imm( 'x16', $bits );
                    $as->fmov_x_to_d( 'd16', 'x16' );
                    $src = 'd16';
                }
                if ( $off < 0 || $off % 8 != 0 ) { $as->stur_d_mem( $src, 'x29', $off ); }
                else                             { $as->str_d_mem( $src, 'x29', $off ); }
            }
            else {
                $as->mov_imm( 'x16', $val ) if $inst->{args}[1] !~ /^%/;
                if ( $off < 0 || $off % 8 != 0 ) { $as->stur_mem_disp_reg( 'x29', $off, $src ); }
                else                             { $as->store_mem_disp_reg( 'x29', $off, $src ); }
            }
        }
        elsif ( $op eq 'local_load' ) {
            my $off = -$inst->{args}[0];
            if ($is_float) {
                if ( $off < 0 || $off % 8 != 0 ) { $as->ldur_d_mem( $d_reg, 'x29', $off ); }
                else                             { $as->ldr_d_mem( $d_reg, 'x29', $off ); }
            }
            else {
                if ( $off < 0 || $off % 8 != 0 ) { $as->ldur_reg_mem( $d_reg, 'x29', $off ); }
                else                             { $as->load_reg_mem( $d_reg, 'x29', $off ); }
            }
        }
        elsif ( $op eq 'store_mem_disp' ) {
            my $src = ( $inst->{args}[2] =~ /^%/ ) ? $reg_map->{ $inst->{args}[2] } : 'x16';
            $as->mov_imm( 'x16', $v->( $inst->{args}[2] ) ) if $inst->{args}[2] !~ /^%/;
            my $off = $inst->{args}[1];
            if ( $off < 0 || $off % 8 != 0 ) { $as->stur_mem_disp_reg( $reg_map->{ $inst->{args}[0] }, $off, $src ); }
            else                             { $as->store_mem_disp_reg( $reg_map->{ $inst->{args}[0] }, $off, $src ); }
        }
        elsif ( $op eq 'load_mem_byte' ) {
            my $base = $reg_map->{ $inst->{args}[0] };
            my $idx  = $inst->{args}[1];
            if ( $idx =~ /^%/ ) {
                $as->add_reg( 'x16', $base, $reg_map->{$idx} );
                $as->ldurb_reg_mem( $d_reg, 'x16', 0 );
            }
            else {
                if ( $idx < 0 ) { $as->ldurb_reg_mem( $d_reg, $base, $idx ); }
                else            { $as->load_reg_mem_byte( $d_reg, $base, $idx ); }
            }
        }
        elsif ( $op eq 'store_mem_byte' ) {
            my $base = $reg_map->{ $inst->{args}[0] };
            my $idx  = $inst->{args}[1];
            my $src  = ( $inst->{args}[2] =~ /^%/ ) ? $reg_map->{ $inst->{args}[2] } : 'x16';
            $as->mov_imm( 'x16', $v->( $inst->{args}[2] ) ) if $inst->{args}[2] !~ /^%/;
            if ( $idx =~ /^%/ ) {
                $as->add_reg( 'x17', $base, $reg_map->{$idx} );
                $as->sturb_mem_disp_reg( 'x17', 0, $src );
            }
            else {
                if ( $idx < 0 ) { $as->sturb_mem_disp_reg( $base, $idx, $src ); }
                else            { $as->store_mem_disp_byte( $base, $idx, $src ); }
            }
        }
        elsif ( $op eq 'load_iso_disp' ) {
            my $off = $inst->{args}[0];
            if ( $off < 0 || $off % 8 != 0 ) { $as->ldur_reg_mem( $d_reg, 'x28', $off ); }
            else                             { $as->load_reg_mem( $d_reg, 'x28', $off ); }
        }
        elsif ( $op eq 'store_iso_disp' ) {
            my $src = ( $inst->{args}[1] =~ /^%/ ) ? $reg_map->{ $inst->{args}[1] } : 'x16';
            $as->mov_imm( 'x16', $v->( $inst->{args}[1] ) ) if $inst->{args}[1] !~ /^%/;
            my $off = $inst->{args}[0];
            if ( $off < 0 || $off % 8 != 0 ) { $as->stur_mem_disp_reg( 'x28', $off, $src ); }
            else                             { $as->store_mem_disp_reg( 'x28', $off, $src ); }
        }
        elsif ( $op eq 'load_func_addr' || $op eq 'load_data_addr' ) {
            my $target = $inst->{args}[0];
            if ( $target =~ /^\d+$/ ) {
                my $base = ( $op eq 'load_data_addr' ) ? $driver->data_rva : 0;
                $as->lea_rva( $d_reg, $base + $target, $driver->text_rva );
            }
            else { $as->lea_rva( $d_reg, $target, $driver->text_rva ); }
        }
        elsif ( $op eq 'get_arg' ) {
            if ($is_float) {
                $as->fmov_reg( $d_reg, $self->_abi_fp_arg_reg( $inst->{args}[0] ) );
            }
            else {
                $as->mov_reg( $d_reg, $self->_abi_arg_reg( $inst->{args}[0] ) );
            }
        }
        elsif ( $op eq 'set_isolate_ctx' ) { $as->mov_reg( 'x28',  $reg_map->{ $inst->{args}[0] } ); }
        elsif ( $op eq 'get_isolate_ctx' ) { $as->mov_reg( $d_reg, 'x28' ); }
        elsif ( $op eq 'enter_func' ) {
            my $regs = $driver->preserved_regs();
            for my $r (@$regs) { $as->push_reg($r); }
            $as->mov_reg( 'x29', 'sp' );
            my $size = $driver->frame_local_size;
            $size = ( $size + 15 ) & ~15;
            $as->sub_imm( 'sp', $size ) if $size > 0;
        }
        elsif ( $op eq 'leave_func' ) {
            my $rv = $v->( $inst->{args}[0] );
            if ( defined $rv ) {
                if ($is_float) {
                    if ( $inst->{args}[0] =~ /^%/ ) {
                        $as->fmov_reg( 'd0', $reg_map->{ $inst->{args}[0] } );
                    }
                    else {
                        my $bits = unpack( 'Q<', pack( 'd<', $rv ) );
                        $as->mov_imm( 'x16', $bits );
                        $as->fmov_x_to_d( 'd0', 'x16' );
                    }
                }
                else {
                    $inst->{args}[0] =~ /^%/ ? $as->mov_reg( 'x0', $reg_map->{ $inst->{args}[0] } ) : $as->mov_imm( 'x0', $rv );
                }
            }
            my $size = $driver->frame_local_size;
            $size = ( $size + 15 ) & ~15;
            $as->add_imm( 'sp', $size ) if $size > 0;
            my $regs = $driver->preserved_regs();
            for my $r ( reverse @$regs ) { $as->pop_reg($r); }
            $as->append_code( pack( 'L<', 0xD65F03C0 ) );    # ret
        }
        elsif ( $op =~ /^call_(func|reg)$/ ) {
            my @args   = @{ $inst->{args} };
            my $target = ( $op eq 'call_func' ) ? shift @args : $reg_map->{ shift @args };
            $as->mov_reg( 'x16', $target ) if $op eq 'call_reg';
            for my $i ( 0 .. $#args ) {
                my $arg = $args[$i];
                my $dst = $self->_abi_arg_reg($i);
                if    ( $arg =~ /^%/ )       { $as->mov_reg( $dst, $reg_map->{$arg} ); }
                elsif ( $arg =~ /^[A-Z_]/i ) { $as->lea_rva( $dst, $arg, $driver->text_rva ); }
                else                         { $as->mov_imm( $dst, $arg ); }
            }
            if   ( $op eq 'call_func' ) { $as->call_label($target); }
            else                        { $as->append_code( pack( 'L<', 0xD63F0200 ) ); }    # blr x16
            $as->mov_reg( $d_reg, 'x0' ) if defined $d_reg;
        }
        elsif ( $op eq 'get_sp' ) { $as->mov_reg( $d_reg, 'sp' ); }
        elsif ( $op eq 'get_bp' ) { $as->mov_reg( $d_reg, 'x29' ); }
        elsif ( $op eq 'map_op' ) {
            $as->mov_imm( $d_reg, 1 ) if defined $d_reg;
        }
        elsif ( $op =~ /^shadow_/ ) {
            if ( $op eq 'shadow_push' ) {
                my $val = $v->( $inst->{args}[0] );
                $as->ldur_reg_mem( 'x15', 'x28', $driver->iso_offset('current_fcb') );
                $as->ldur_reg_mem( 'x17', 'x15', $driver->fcb_offset('shadow_ptr') );
                if ( $inst->{args}[0] =~ /^%/ ) { $as->stur_mem_disp_reg( 'x17', 0, $reg_map->{ $inst->{args}[0] } ); }
                else                            { $as->mov_imm( 'x16', $val ); $as->stur_mem_disp_reg( 'x17', 0, 'x16' ); }
                $as->add_imm( 'x17', 8 );
                $as->stur_mem_disp_reg( 'x15', $driver->fcb_offset('shadow_ptr'), 'x17' );
            }
            elsif ( $op eq 'shadow_get' ) {
                $as->ldur_reg_mem( 'x16',  'x28', $driver->iso_offset('current_fcb') );
                $as->ldur_reg_mem( $d_reg, 'x16', $driver->fcb_offset('shadow_ptr') );
            }
            elsif ( $op =~ /^shadow_(set|restore)$/ ) {
                $as->ldur_reg_mem( 'x16', 'x28', $driver->iso_offset('current_fcb') );
                $as->stur_mem_disp_reg( 'x16', $driver->fcb_offset('shadow_ptr'), $v->( $inst->{args}[0] ) );
            }
        }
        elsif ( $op eq 'shadow_pop' ) {
            $as->ldur_reg_mem( 'x15', 'x28', $driver->iso_offset('current_fcb') );
            $as->ldur_reg_mem( 'x17', 'x15', $driver->fcb_offset('shadow_ptr') );
            $as->sub_imm( 'x17', 8 );
            $as->stur_mem_disp_reg( 'x15', $driver->fcb_offset('shadow_ptr'), 'x17' );
        }
        elsif ( $op =~ /^(local|atomic)_(inc|dec)_ref$/ ) {
            my $is_atomic = $1 eq 'atomic';
            my $is_inc    = $2 eq 'inc';
            my $obj       = $reg_map->{ $inst->{args}[0] };
            $as->mov_reg( 'x15', $obj );
            $as->sub_imm( 'x15', 8 );    # Point to header
            $as->mov_imm( 'x16', 1 << 48 );
            if ($is_atomic) {
                my $l_retry = "L_atomic_rc_" . $driver->next_label_id;
                $as->mark_label($l_retry);
                $as->ldxr_reg( 'x17', 'x15' );
                if ($is_inc) { $as->add_reg( 'x17', 'x17', 'x16' ); }
                else         { $as->sub_reg( 'x17', 'x17', 'x16' ); }
                $as->stxr_reg( 'w18', 'x17', 'x15' );
                $as->cbnz_label( 'w18', $l_retry );
            }
            else {
                $as->ldur_reg_mem( 'x17', 'x15', 0 );
                if ($is_inc) { $as->add_reg( 'x17', 'x17', 'x16' ); }
                else         { $as->sub_reg( 'x17', 'x17', 'x16' ); }
                $as->stur_mem_disp_reg( 'x15', 0, 'x17' );
            }
        }
    }

    method compile_intrinsic( $as, $inst, $reg_map, $driver ) {
        my $op    = $inst->{op};
        my $v     = sub { $self->val( $reg_map, shift ) };
        my $d_reg = $reg_map->{ $inst->{dest} } if $inst->{dest};
        if ( $op eq 'intrinsic_get_text_base' ) {
            $as->lea_rva( $d_reg, 'TEXT:0', $driver->text_rva );
            return;
        }
        if ( $op eq 'intrinsic_throw' ) {
            my $exc = $v->( $inst->{args}[0] );
            $as->ldur_reg_mem( 'x15', 'x28', $driver->iso_offset('current_fcb') );
            if ( $inst->{args}[0] =~ /^%/ ) {
                $as->stur_mem_disp_reg( 'x15', $driver->fcb_offset('exception_obj'), $reg_map->{ $inst->{args}[0] } );
            }
            else {
                $as->mov_imm( 'x16', $exc );
                $as->stur_mem_disp_reg( 'x15', $driver->fcb_offset('exception_obj'), 'x16' );
            }
            $as->call_label('M_unwind');
            return;
        }
        if ( $op eq 'intrinsic_get_exception' ) {
            $as->ldur_reg_mem( 'x15',  'x28', $driver->iso_offset('current_fcb') );
            $as->ldur_reg_mem( $d_reg, 'x15', $driver->fcb_offset('exception_obj') );
            return;
        }
        if ( $op eq 'intrinsic_clear_exception' ) {
            $as->ldur_reg_mem( 'x15', 'x28', $driver->iso_offset('current_fcb') );
            $as->mov_imm( 'x16', 0 );
            $as->stur_mem_disp_reg( 'x15', $driver->fcb_offset('exception_obj'), 'x16' );
            return;
        }
        if ( $op eq 'intrinsic_restore_context' ) {
            my $target_bp = $reg_map->{ $inst->{args}[0] };
            my $target_pc = $reg_map->{ $inst->{args}[1] };
            my $source_bp = $reg_map->{ $inst->{args}[2] };

            # 1. Load target context into scratch registers and set SP to source_bp where registers are saved
            $as->mov_reg( 'x16', $target_pc );
            $as->mov_reg( 'x17', $target_bp );
            $as->mov_reg( 'sp',  $source_bp );

            # 2. Restore callee-saved registers from the source frame
            for my $r ( reverse @{ $driver->preserved_regs() } ) {
                $as->pop_reg($r);
            }

            # 3. Set Frame Pointer to target frame and adjust SP for locals
            $as->mov_reg( 'x29', 'x17' );
            $as->mov_reg( 'sp',  'x29' );
            my $size = $driver->frame_local_size;
            $size = ( $size + 15 ) & ~15;
            $as->sub_imm( 'sp', $size ) if $size > 0;
            $as->append_code( pack( 'L<', 0xD61F0200 ) );    # br x16
            return;
        }
        return $driver->platform->emit_intrinsic( $self, $as, $inst, $reg_map, $driver );
    }

    method new_assembler() {
        return Brocken::Target::ARM64::Emit->new();
    }
}

class Brocken::Target::ARM64::Emit {
    our %REG = (
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
        ( map { ( "d$_" => $_, "s$_" => $_, "v$_" => $_ ) } 0 .. 31 )
    );
    field $code : reader = '';
    field %labels;
    field @fixups;
    method reg($r)           { $REG{ lc $r } // die 'Unknown ARM64 register: ' . $r }
    method append_code($bin) { $code .= $bin }

    method push_reg($reg) {
        my $r = $self->reg($reg);

        # STR Rt, [SP, #-16]!  (Pre-indexed with writeback)
        $code .= pack( 'L<', 0xF81F0FE0 | $r );
    }

    method pop_reg($reg) {
        my $r = $self->reg($reg);

        # LDR Rt, [SP], #16    (Post-indexed)
        $code .= pack( 'L<', 0xF84107E0 | $r );
    }
    method push_imm($imm)         { $self->mov_imm( 'x16', $imm ); $self->push_reg('x16'); }
    method fadd_reg( $d, $n, $m ) { $code .= pack( 'L<', 0x1E602800 | ( $self->reg($m) << 16 ) | ( $self->reg($n) << 5 ) | $self->reg($d) ); }
    method fsub_reg( $d, $n, $m ) { $code .= pack( 'L<', 0x1E603800 | ( $self->reg($m) << 16 ) | ( $self->reg($n) << 5 ) | $self->reg($d) ); }
    method fmul_reg( $d, $n, $m ) { $code .= pack( 'L<', 0x1E600800 | ( $self->reg($m) << 16 ) | ( $self->reg($n) << 5 ) | $self->reg($d) ); }
    method fmov_reg( $d, $n )     { $code .= pack( 'L<', 0x1E604000 | ( $self->reg($n) << 5 ) | $self->reg($d) ); }
    method fmov_x_to_d( $d, $n )  { $code .= pack( 'L<', 0x9E670000 | ( $self->reg($n) << 5 ) | $self->reg($d) ); }
    method fmov_d_to_x( $d, $n )  { $code .= pack( 'L<', 0x9E660000 | ( $self->reg($n) << 5 ) | $self->reg($d) ); }
    method fcmp_reg( $n, $m )     { $code .= pack( 'L<', 0x1E602000 | ( $self->reg($m) << 16 ) | ( $self->reg($n) << 5 ) ); }

    method ldr_d_mem( $d, $n, $disp = 0 ) {
        $code .= pack( 'L<', 0xFD400000 | ( ( ( $disp >> 3 ) & 0xFFF ) << 10 ) | ( $self->reg($n) << 5 ) | $self->reg($d) );
    }

    method str_d_mem( $d, $n, $disp = 0 ) {
        $code .= pack( 'L<', 0xFD000000 | ( ( ( $disp >> 3 ) & 0xFFF ) << 10 ) | ( $self->reg($n) << 5 ) | $self->reg($d) );
    }

    method ldur_d_mem( $d, $n, $disp = 0 ) {
        $code .= pack( 'L<', 0xFC400000 | ( ( $disp & 0x1FF ) << 12 ) | ( $self->reg($n) << 5 ) | $self->reg($d) );
    }

    method stur_d_mem( $d, $n, $disp = 0 ) {
        $code .= pack( 'L<', 0xFC000000 | ( ( $disp & 0x1FF ) << 12 ) | ( $self->reg($n) << 5 ) | $self->reg($d) );
    }

    method mov_imm( $r, $imm ) {
        my $ri = $self->reg($r);
        my $v  = $imm;
        if ( $v >= 0 && $v <= 0xFFFF ) {
            $code .= pack( 'L<', 0xD2800000 | ( ( $v & 0xFFFF ) << 5 ) | $ri );
        }
        else {
            my $first = 1;
            for my $hw ( 0 .. 3 ) {
                my $chunk = ( $v >> ( $hw * 16 ) ) & 0xFFFF;
                if ($first) {
                    $code .= pack( 'L<', 0xD2800000 | ( $hw << 21 ) | ( $chunk << 5 ) | $ri );
                    $first = 0;
                }
                elsif ( $chunk != 0 ) {
                    $code .= pack( 'L<', 0xF2800000 | ( $hw << 21 ) | ( $chunk << 5 ) | $ri );
                }
            }
            if ($first) { $code .= pack( 'L<', 0xD2800000 | $ri ); }
        }
    }

    method mov_reg( $dest, $src ) {
        my $d = $self->reg($dest);
        my $s = $self->reg($src);
        if ( $dest eq 'sp' || $src eq 'sp' ) {
            $code .= pack( 'L<', 0x91000000 | ( $s << 5 ) | $d );
        }
        else {
            $code .= pack( 'L<', 0xAA0003E0 | ( $s << 16 ) | $d );
        }
    }

    method add_imm( $reg, $imm ) {
        my $r = $self->reg($reg);
        $code .= pack( 'L<', 0x91000000 | ( ( $imm & 0xFFF ) << 10 ) | ( $r << 5 ) | $r );
    }

    method sub_imm( $reg, $imm ) {
        my $r = $self->reg($reg);
        $code .= pack( 'L<', 0xD1000000 | ( ( $imm & 0xFFF ) << 10 ) | ( $r << 5 ) | $r );
    }

    method add_reg( $dest, $rn, $rm ) {
        my $d = $self->reg($dest);
        my $n = $self->reg($rn);
        my $m = $self->reg($rm);
        $code .= pack( 'L<', 0x8B000000 | ( $m << 16 ) | ( $n << 5 ) | $d );
    }

    method sub_reg( $dest, $rn, $rm ) {
        my $d = $self->reg($dest);
        my $n = $self->reg($rn);
        my $m = $self->reg($rm);
        $code .= pack( 'L<', 0xCB000000 | ( $m << 16 ) | ( $n << 5 ) | $d );
    }

    method mul_reg( $dest, $rn, $rm ) {
        my $d = $self->reg($dest);
        my $n = $self->reg($rn);
        my $m = $self->reg($rm);
        $code .= pack( 'L<', 0x9B007C00 | ( $m << 16 ) | ( $n << 5 ) | $d );
    }

    method msub_reg( $dest, $rn, $rm, $ra ) {
        my $d = $self->reg($dest);
        my $n = $self->reg($rn);
        my $m = $self->reg($rm);
        my $a = $self->reg($ra);
        $code .= pack( 'L<', 0x9B008000 | ( $m << 16 ) | ( $a << 10 ) | ( $n << 5 ) | $d );
    }

    method cmp_reg_reg( $l, $r ) {
        my $ld = $self->reg($l);
        my $rd = $self->reg($r);
        $code .= pack( 'L<', 0xEB000000 | ( $rd << 16 ) | 31 | ( $ld << 5 ) );
    }

    method cmp_reg_imm( $reg, $imm ) {
        my $r = $self->reg($reg);
        $code .= pack( 'L<', 0xF1000000 | ( ( $imm & 0xFFF ) << 10 ) | ( $r << 5 ) | 31 );
    }

    method sdiv_reg( $dest, $rn, $rm ) {
        my $d = $self->reg($dest);
        my $n = $self->reg($rn);
        my $m = $self->reg($rm);
        $code .= pack( 'L<', 0x9AC00800 | ( $m << 16 ) | ( $n << 5 ) | $d );
    }

    method lsl_imm( $dest, $src, $amt ) {
        my $d = $self->reg($dest);
        my $s = $self->reg($src);
        $amt &= 0x3F;
        my $immr = ( -$amt ) & 0x3F;
        my $imms = 63 - $amt;
        $code .= pack( 'L<', 0xD3400000 | ( $immr << 16 ) | ( $imms << 10 ) | ( $s << 5 ) | $d );
    }

    method lsr_imm( $dest, $src, $amt ) {
        my $d = $self->reg($dest);
        my $s = $self->reg($src);
        $amt &= 0x3F;
        $code .= pack( 'L<', 0xD340FC00 | ( $amt << 16 ) | ( $s << 5 ) | $d );
    }

    method lsl_reg( $dest, $src, $amt ) {
        my $d = $self->reg($dest);
        my $s = $self->reg($src);
        my $a = $self->reg($amt);
        $code .= pack( 'L<', 0x9AC02000 | ( $a << 16 ) | ( $s << 5 ) | $d );
    }

    method lsr_reg( $dest, $src, $amt ) {
        my $d = $self->reg($dest);
        my $s = $self->reg($src);
        my $a = $self->reg($amt);
        $code .= pack( 'L<', 0x9AC02400 | ( $a << 16 ) | ( $s << 5 ) | $d );
    }

    method and_reg( $dest, $rn, $rm ) {
        my $d = $self->reg($dest);
        my $n = $self->reg($rn);
        my $m = $self->reg($rm);
        $code .= pack( 'L<', 0x8A000000 | ( $m << 16 ) | ( $n << 5 ) | $d );
    }

    method or_reg( $dest, $rn, $rm ) {
        my $d = $self->reg($dest);
        my $n = $self->reg($rn);
        my $m = $self->reg($rm);
        $code .= pack( 'L<', 0xAA000000 | ( $m << 16 ) | ( $n << 5 ) | $d );
    }

    method xor_reg( $dest, $rn, $rm ) {
        my $d = $self->reg($dest);
        my $n = $self->reg($rn);
        my $m = $self->reg($rm);
        $code .= pack( 'L<', 0xCA000000 | ( $m << 16 ) | ( $n << 5 ) | $d );
    }

    method setcc( $cc, $r ) {
        my $ri     = $self->reg($r);
        my $inv_cc = $cc ^ 1;
        $code .= pack( 'L<', 0x9A9F07E0 | ( $inv_cc << 12 ) | $ri );
    }

    method test_reg_reg( $l, $r ) {
        my $ld = $self->reg($l);
        my $rd = $self->reg($r);
        $code .= pack( 'L<', 0xEA000000 | ( $rd << 16 ) | ( $ld << 5 ) | 31 );
    }

    method ldxr_reg( $d, $n ) {
        $code .= pack( 'L<', 0xC85F7C00 | ( $self->reg($n) << 5 ) | $self->reg($d) );
    }

    method stxr_reg( $s, $d, $n ) {
        $code .= pack( 'L<', 0xC8007C00 | ( $self->reg($s) << 16 ) | ( $self->reg($n) << 5 ) | $self->reg($d) );
    }

    method cbnz_label( $r, $l ) {
        push @fixups, { offset => length($code), target => $l, type => 'cond_br' };
        $code .= pack( 'L<', 0xB5000000 | $self->reg($r) );
    }

    method load_reg_mem( $dest, $src, $disp = 0 ) {
        my $d = $self->reg($dest);
        my $s = $self->reg($src);
        $code .= pack( 'L<', 0xF9400000 | ( ( ( $disp >> 3 ) & 0xFFF ) << 10 ) | ( $s << 5 ) | $d );
    }

    method store_mem_disp_reg( $base, $disp, $src ) {
        my $b = $self->reg($base);
        my $s = $self->reg($src);
        $code .= pack( 'L<', 0xF9000000 | ( ( ( $disp >> 3 ) & 0xFFF ) << 10 ) | ( $b << 5 ) | $s );
    }

    method load_reg_mem_byte( $dest, $src, $disp = 0 ) {
        my $d = $self->reg($dest);
        my $s = $self->reg($src);
        $code .= pack( 'L<', 0x39400000 | ( ( $disp & 0xFFF ) << 10 ) | ( $s << 5 ) | $d );
    }

    method store_mem_disp_byte( $base, $disp, $src ) {
        my $b = $self->reg($base);
        my $s = $self->reg($src);
        $code .= pack( 'L<', 0x39000000 | ( ( $disp & 0xFFF ) << 10 ) | ( $b << 5 ) | $s );
    }

    method ldur_reg_mem( $dest, $src, $disp = 0 ) {
        my $d = $self->reg($dest);
        my $s = $self->reg($src);
        $code .= pack( 'L<', 0xF8400000 | ( ( $disp & 0x1FF ) << 12 ) | ( $s << 5 ) | $d );
    }

    method stur_mem_disp_reg( $base, $disp, $src ) {
        my $b = $self->reg($base);
        my $s = $self->reg($src);
        $code .= pack( 'L<', 0xF8000000 | ( ( $disp & 0x1FF ) << 12 ) | ( $b << 5 ) | $s );
    }

    method ldurb_reg_mem( $dest, $src, $disp = 0 ) {
        my $d = $self->reg($dest);
        my $s = $self->reg($src);
        $code .= pack( 'L<', 0x38400000 | ( ( $disp & 0x1FF ) << 12 ) | ( $s << 5 ) | $d );
    }

    method sturb_mem_disp_reg( $base, $disp, $src ) {
        my $b = $self->reg($base);
        my $s = $self->reg($src);
        $code .= pack( 'L<', 0x38000000 | ( ( $disp & 0x1FF ) << 12 ) | ( $b << 5 ) | $s );
    }

    method lea_rva( $reg, $target, $txtrva = 0 ) {
        my $r = $self->reg($reg);
        if ( !defined $target ) { die "lea_rva: target is undefined" }
        if ( $target =~ /^([A-Z_]|DATA:)/i ) {
            push @fixups, { offset => length($code), target => $target, type => 'adr' };
            $code .= pack( 'L<', 0x10000000 | $r );
        }
        else {
            my $off = $target - ( $txtrva + length($code) );
            my $lo  = $off & 0x3;
            my $hi  = ( $off >> 2 ) & 0x7FFFF;
            $code .= pack( 'L<', 0x10000000 | ( $lo << 29 ) | ( $hi << 5 ) | $r );
        }
    }
    method call_label($l)    { push @fixups, { offset => length($code), target => $l, type => 'call' }; $code .= pack( 'L<', 0x94000000 ) }
    method syscall( $m = 0 ) { $code .= pack( 'L<', $m ? 0xD4001001 : 0xD4000001 ) }

    method jcc( $cc, $l ) {
        push @fixups, { offset => length($code), target => $l, type => 'cond', cc => $cc };
        $code .= pack( 'L<', 0x54000000 | $cc );
    }
    method jmp($l)        { push @fixups, { offset => length($code), target => $l, type => 'uncond' }; $code .= pack( 'L<', 0x14000000 ) }
    method mark_label($n) { $labels{$n} = length $code }

    method resolve( $text_rva = 0, $data_rva = 0 ) {
        for (@fixups) {
            my $target = $_->{target};
            my $t;
            if ( $target =~ /^DATA:(\d+)$/ ) {
                $t = $1 + $data_rva - $text_rva;
            }
            else {
                $t = $labels{$target};
                die "Linker Error: Unresolved label '$target'\n" unless defined $t;
            }
            my $off   = ( $t - $_->{offset} );
            my $instr = unpack( 'L<', substr( $code, $_->{offset}, 4 ) );
            if ( $_->{type} eq 'cond' || $_->{type} eq 'cond_br' ) {
                my $woff = $off / 4;
                $instr |= ( $woff & 0x7FFFF ) << 5;
            }
            elsif ( $_->{type} eq 'call' || $_->{type} eq 'uncond' ) {
                my $woff = $off / 4;
                $instr |= ( $woff & 0x3FFFFFF );
            }
            elsif ( $_->{type} eq 'adr' ) {
                my $lo = $off & 0x3;
                my $hi = ( $off >> 2 ) & 0x7FFFF;
                $instr |= ( $lo << 29 ) | ( $hi << 5 );
            }
            substr( $code, $_->{offset}, 4, pack( 'L<', $instr ) );
        }
    }

    method call_rva( $trva, $txtrva ) {
        my $off = ( $trva - ( $txtrva + length($code) ) ) / 4;
        $code .= pack( 'L<', 0x94000000 | ( $off & 0x3FFFFFF ) );
    }
}
1;
__END__

=pod

=head1 NAME

Brocken::Target::ARM64 - ARM64 CPU target implementation

=head1 SYNOPSIS

    my $target = Brocken::Target::ARM64->new( os => 'linux', arch => 'arm64' );
    my @regs = @{ $target->registers };
    $target->emit_op($as, $inst, \%reg_map, $compiler);

=head1 DESCRIPTION

Implements the L<Brocken::Target> interface for the ARM64 (AArch64) architecture. Handles the mapping of Brocken IR to
ARM64 machine code, manages the ARM64 register pool, and follows the standard AArch64 ABI.

=head1 METHODS

=head2 registers

Returns the list of available callee-saved registers (x19-x27). x28 is reserved for the Isolate context.

=head2 fp_registers

Returns the list of available SIMD/FP registers (d8-d15).

=head2 compile_intrinsic($as, $inst, $reg_map, $driver)

Delegates intrinsic compilation to the current platform module.

=head2 new_assembler

Returns a new L<Brocken::Target::ARM64::Emit> instance.

=head2 emit_op($as, $inst, $reg_map, $driver)

Translates Brocken IR instructions into ARM64 machine instructions.

=cut
