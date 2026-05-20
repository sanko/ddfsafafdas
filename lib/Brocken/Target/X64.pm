use v5.40;
use feature 'class';
no warnings 'experimental::class';

class Brocken::Target::X64 : isa(Brocken::Target) {

    method registers() {

        # Reserve R14 for Isolate and R10/R11 for internal compiler use
        return $self->os eq 'win64' ? [qw(rbx rsi rdi r12 r13 r15)] : [qw(rbx r12 r13 r15)];
    }

    method fp_registers() {

        # XMM registers for floating point (SSE2)
        return [qw(xmm0 xmm1 xmm2 xmm3 xmm4 xmm5 xmm6 xmm7)];
    }

    method _abi_arg_reg($idx) {
        if   ( $self->os eq 'win64' ) { return (qw[rcx rdx r8 r9])[$idx]         // $idx; }
        else                          { return (qw[rdi rsi rdx rcx r8 r9])[$idx] // $idx; }
    }

    method _abi_fp_arg_reg($idx) {

        # Float/double args go in XMM registers on x64
        return (qw[xmm0 xmm1 xmm2 xmm3])[$idx] // "xmm$idx";
    }

    method _abi_fp_return_reg() {

        # Float/double return value in XMM0
        return 'xmm0';
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
            $as->load_reg_mem( 'r11', 'r14', $driver->iso_offset('current_fcb') );
            if ( $inst->{args}[0] =~ /^%/ ) {
                $as->store_mem_disp_reg( 'r11', $driver->fcb_offset('exception_obj'), $reg_map->{ $inst->{args}[0] } );
            }
            else {
                $as->mov_imm( 'r10', $exc );
                $as->store_mem_disp_reg( 'r11', $driver->fcb_offset('exception_obj'), 'r10' );
            }
            $as->call_label('M_unwind');
            return;
        }
        if ( $op eq 'intrinsic_get_exception' ) {
            $as->load_reg_mem( 'r11',  'r14', $driver->iso_offset('current_fcb') );
            $as->load_reg_mem( $d_reg, 'r11', $driver->fcb_offset('exception_obj') );
            return;
        }
        if ( $op eq 'intrinsic_clear_exception' ) {
            $as->load_reg_mem( 'r11', 'r14', $driver->iso_offset('current_fcb') );
            $as->mov_imm( 'r10', 0 );
            $as->store_mem_disp_reg( 'r11', $driver->fcb_offset('exception_obj'), 'r10' );
            return;
        }
        if ( $op eq 'intrinsic_restore_context' ) {
            my $target_bp = $reg_map->{ $inst->{args}[0] };
            my $target_pc = $reg_map->{ $inst->{args}[1] };
            my $source_bp = $reg_map->{ $inst->{args}[2] };

            # 1. Load target context into scratch registers and set RSP to source_bp where registers are saved
            $as->mov_reg( 'r11', $target_pc );
            $as->mov_reg( 'r10', $target_bp );
            $as->mov_reg( 'rsp', $source_bp );

            # 2. Restore callee-saved registers from the source frame
            # This restores the register state as it was when the source frame called its child.
            for my $r ( reverse @{ $driver->preserved_regs() } ) {
                $as->pop_reg($r);
            }

            # 3. Now set the Frame Pointer to the target frame and adjust RSP for locals
            $as->mov_reg( 'rbp', 'r10' );
            $as->mov_reg( 'rsp', 'rbp' );
            $as->sub_imm( 'rsp', $driver->frame_local_size );

            # 4. Jump to catch/finally in the target frame
            $as->jmp_reg('r11');
            return;
        }
        return $driver->platform->emit_intrinsic( $self, $as, $inst, $reg_map, $driver );
    }

    method new_assembler() {
        return Brocken::Target::X64::Emit->new();
    }

    method emit_op( $as, $inst, $reg_map, $driver ) {
        my $op    = $inst->{op};
        my $v     = sub { $self->val( $reg_map, shift ) };
        my $d_reg = $reg_map->{ $inst->{dest} } if $inst->{dest};
        if    ( $op eq 'jmp' ) { $as->jmp( $inst->{target} ); }
        elsif ( $op eq 'cond_br' ) {
            my $reg = $v->( $inst->{reg} );
            $as->test_reg_reg( $reg, $reg );
            $as->jcc( $driver->cc('nz'), $inst->{true_l} );
            $as->jmp( $inst->{false_l} );
        }
        elsif ( $op eq 'constant' ) {
            if ( $inst->{type} && ( $inst->{type} eq 'double' || $inst->{type} eq 'float' ) ) {

                # Load 64-bit floating point bit pattern directly into GP register
                my $bits = unpack( 'Q<', pack( 'd<', $inst->{args}[0] // 0.0 ) );
                $as->mov_imm( $d_reg, $bits );
            }
            else {
                $as->mov_imm( $d_reg, $inst->{args}[0] );
            }
        }
        elsif ( $op eq 'mov' ) {
            my $src = $inst->{args}[0];
            if ( $src =~ /^%/ ) { $as->mov_reg( $d_reg, $reg_map->{$src} ) if $d_reg ne $reg_map->{$src}; }
            else                { $as->mov_imm( $d_reg, $v->($src) ); }
        }
        elsif ( $op =~ /^(add|sub|mul|and|or|xor|div|mod)$/ ) {
            my ( $l_raw, $r_raw ) = @{ $inst->{args} };
            my $is_float = ( $inst->{type} && ( $inst->{type} eq 'double' || $inst->{type} eq 'float' ) );
            if ( $is_float && $op =~ /^(add|sub|mul|div)$/ ) {

                # Move GP stored floats into XMM0/XMM1 temps
                if ( $l_raw =~ /^%/ ) {
                    $as->movq_reg_xmm( 'xmm0', $reg_map->{$l_raw} );
                }
                else {
                    my $bits = unpack( 'Q<', pack( 'd<', $v->($l_raw) // 0.0 ) );
                    $as->mov_imm( 'r10', $bits );
                    $as->movq_reg_xmm( 'xmm0', 'r10' );
                }
                if ( $r_raw =~ /^%/ ) {
                    $as->movq_reg_xmm( 'xmm1', $reg_map->{$r_raw} );
                }
                else {
                    my $bits = unpack( 'Q<', pack( 'd<', $v->($r_raw) // 0.0 ) );
                    $as->mov_imm( 'r11', $bits );
                    $as->movq_reg_xmm( 'xmm1', 'r11' );
                }
                if    ( $op eq 'add' ) { $as->addsd_reg( 'xmm0', 'xmm1' ) }
                elsif ( $op eq 'sub' ) { $as->subsd_reg( 'xmm0', 'xmm1' ) }
                elsif ( $op eq 'mul' ) { $as->mulsd_reg( 'xmm0', 'xmm1' ) }
                elsif ( $op eq 'div' ) { $as->divsd_reg( 'xmm0', 'xmm1' ) }

                # Move result back to GP
                $as->movq_xmm_reg( $d_reg, 'xmm0' ) if defined $d_reg;
            }
            elsif ( $op =~ /^(div|mod)$/ ) {
                $as->push_reg('rdx');
                $as->push_reg('rax');
                if ( $l_raw =~ /^%/ ) { $as->mov_reg( 'rax', $reg_map->{$l_raw} ); }
                else                  { $as->mov_imm( 'rax', $v->($l_raw) ); }
                $as->append_code( pack( 'CC', 0x48, 0x99 ) );    # CQO
                if   ( $r_raw =~ /^%/ ) { $as->idiv_reg( $reg_map->{$r_raw} ); }
                else                    { $as->mov_imm( 'r11', $v->($r_raw) ); $as->idiv_reg('r11'); }
                $as->mov_reg( 'r10', ( $op eq 'div' ? 'rax' : 'rdx' ) );
                $as->pop_reg('rax');
                $as->pop_reg('rdx');
                $as->mov_reg( $d_reg, 'r10' );
            }
            else {
                # Integer Add/Sub/Mul/Logical
                if ( $l_raw !~ /^%/ ) { $as->mov_imm( $d_reg, $v->($l_raw) ); }
                else                  { $as->mov_reg( $d_reg, $reg_map->{$l_raw} ) if $d_reg ne $reg_map->{$l_raw}; }
                if ( $r_raw =~ /^%/ ) {
                    my $rs = $reg_map->{$r_raw};
                    if    ( $op eq 'add' ) { $as->add_reg( $d_reg, $rs ) }
                    elsif ( $op eq 'sub' ) { $as->sub_reg( $d_reg, $rs ) }
                    elsif ( $op eq 'and' ) { $as->and_reg( $d_reg, $rs ) }
                    elsif ( $op eq 'or' )  { $as->or_reg( $d_reg, $rs ) }
                    elsif ( $op eq 'xor' ) { $as->xor_reg( $d_reg, $rs ) }
                    else                   { $as->mul_reg( $d_reg, $rs ) }
                }
                else {
                    my $imm = $v->($r_raw);
                    if ( $imm > 2147483647 || $imm < -2147483648 ) {
                        $as->mov_imm( 'r11', $imm );
                        if    ( $op eq 'add' ) { $as->add_reg( $d_reg, 'r11' ) }
                        elsif ( $op eq 'sub' ) { $as->sub_reg( $d_reg, 'r11' ) }
                        elsif ( $op eq 'and' ) { $as->and_reg( $d_reg, 'r11' ) }
                        elsif ( $op eq 'or' )  { $as->or_reg( $d_reg, 'r11' ) }
                        elsif ( $op eq 'xor' ) { $as->xor_reg( $d_reg, 'r11' ) }
                        else                   { $as->mul_reg( $d_reg, 'r11' ) }
                    }
                    else {
                        if    ( $op eq 'add' ) { $as->add_imm( $d_reg, $imm ) }
                        elsif ( $op eq 'sub' ) { $as->sub_imm( $d_reg, $imm ) }
                        elsif ( $op eq 'and' ) { $as->and_imm( $d_reg, $imm ) }
                        elsif ( $op eq 'or' )  { $as->or_imm( $d_reg, $imm ) }
                        elsif ( $op eq 'xor' ) { $as->xor_imm( $d_reg, $imm ) }
                        else                   { $as->mov_imm( 'r11', $imm ); $as->mul_reg( $d_reg, 'r11' ); }
                    }
                }
            }
        }
        elsif ( $op =~ /^(shl|shr)$/ ) {
            my ( $val_raw, $amt_raw ) = @{ $inst->{args} };
            if ( $val_raw =~ /^%/ ) { $as->mov_reg( $d_reg, $reg_map->{$val_raw} ) if $d_reg ne $reg_map->{$val_raw}; }
            else                    { $as->mov_imm( $d_reg, $v->($val_raw) ); }
            if ( $amt_raw =~ /^%/ ) {
                $as->mov_reg( 'rcx', $reg_map->{$amt_raw} );
                if   ( $op eq 'shl' ) { $as->shl_cl($d_reg) }
                else                  { $as->shr_cl($d_reg) }
            }
            else {
                if ( $op eq 'shl' ) { $as->shl_imm( $d_reg, $v->($amt_raw) ) }
                else                { $as->shr_imm( $d_reg, $v->($amt_raw) ) }
            }
        }
        elsif ( $op =~ /^cmp_/ ) {
            my ( $l_raw, $r_raw ) = @{ $inst->{args} };
            my $is_float = ( $inst->{type} && ( $inst->{type} eq 'double' || $inst->{type} eq 'float' ) );
            if ($is_float) {
                if ( $l_raw =~ /^%/ ) { $as->movq_reg_xmm( 'xmm0', $reg_map->{$l_raw} ); }
                else {
                    my $bits = unpack( 'Q<', pack( 'd<', $v->($l_raw) // 0.0 ) );
                    $as->mov_imm( 'r10', $bits );
                    $as->movq_reg_xmm( 'xmm0', 'r10' );
                }
                if ( $r_raw =~ /^%/ ) { $as->movq_reg_xmm( 'xmm1', $reg_map->{$r_raw} ); }
                else {
                    my $bits = unpack( 'Q<', pack( 'd<', $v->($r_raw) // 0.0 ) );
                    $as->mov_imm( 'r11', $bits );
                    $as->movq_reg_xmm( 'xmm1', 'r11' );
                }
                $as->ucomisd_reg( 'xmm0', 'xmm1' );
                $as->mov_imm( $d_reg, 0 );
                my $cc = { eq => 0x94, ne => 0x95, lt => 0x92, gt => 0x97, le => 0x96, ge => 0x93 }->{ substr( $op, 4 ) };
                $as->setcc( $cc, $d_reg );
            }
            else {
                my $l_reg = ( $l_raw =~ /^%/ ) ? $reg_map->{$l_raw} : 'r10';
                $as->mov_imm( 'r10', $v->($l_raw) ) if $l_raw !~ /^%/;
                if ( $r_raw =~ /^%/ ) {
                    $as->cmp_reg_reg( $l_reg, $reg_map->{$r_raw} );
                }
                else {
                    my $imm = $v->($r_raw);
                    if ( $imm > 2147483647 || $imm < -2147483648 ) {
                        $as->mov_imm( 'r11', $imm );
                        $as->cmp_reg_reg( $l_reg, 'r11' );
                    }
                    else {
                        $as->cmp_reg_imm( $l_reg, $imm );
                    }
                }
                $as->mov_imm( $d_reg, 0 );
                my $cc = { eq => 0x94, ne => 0x95, lt => 0x9C, gt => 0x9F, le => 0x9E, ge => 0x9D }->{ substr( $op, 4 ) };
                $as->setcc( $cc, $d_reg );
            }
        }
        elsif ( $op eq 'local_store' ) {
            my $src = $inst->{args}[1];
            if ( $src !~ /^%/ ) {
                $as->mov_imm( 'r11', $v->($src) );
                $as->store_mem_disp_reg( 'rbp', -$inst->{args}[0], 'r11' );
            }
            else {
                $as->store_mem_disp_reg( 'rbp', -$inst->{args}[0], $reg_map->{$src} );
            }
        }
        elsif ( $op eq 'local_load' ) {
            $as->load_reg_mem( $d_reg, 'rbp', -$inst->{args}[0] );
        }
        elsif ( $op eq 'store_mem_disp' ) {
            my $src = ( $inst->{args}[2] =~ /^%/ ) ? $reg_map->{ $inst->{args}[2] } : 'r11';
            $as->mov_imm( 'r11', $v->( $inst->{args}[2] ) ) if $inst->{args}[2] !~ /^%/;
            $as->store_mem_disp_reg( $reg_map->{ $inst->{args}[0] }, $inst->{args}[1], $src );
        }
        elsif ( $op eq 'load_mem_disp' ) { $as->load_reg_mem( $d_reg, $reg_map->{ $inst->{args}[0] }, $inst->{args}[1] ); }
        elsif ( $op eq 'load_mem_byte' ) {
            my ( $base, $idx ) = ( $reg_map->{ $inst->{args}[0] }, $inst->{args}[1] );
            if ( $idx =~ /^%/ ) {
                $as->mov_reg( 'r11', $base );
                $as->add_reg( 'r11', $reg_map->{$idx} );
                $as->load_reg_mem_byte( $d_reg, 'r11', 0 );
            }
            else { $as->load_reg_mem_byte( $d_reg, $base, $idx ); }
        }
        elsif ( $op eq 'store_mem_byte' ) {
            my ( $base, $idx, $src_raw ) = @{ $inst->{args} };
            my $src = ( $src_raw =~ /^%/ ) ? $reg_map->{$src_raw} : 'r11';
            $as->mov_imm( 'r11', $v->($src_raw) ) if $src_raw !~ /^%/;
            if ( $idx =~ /^%/ ) {
                $as->mov_reg( 'r10', $reg_map->{$base} );
                $as->add_reg( 'r10', $reg_map->{$idx} );
                $as->store_mem_disp_byte( 'r10', 0, $src );
            }
            else { $as->store_mem_disp_byte( $reg_map->{$base}, $idx, $src ); }
        }
        elsif ( $op =~ /^call_/ || $op =~ /^tail_call_/ ) {
            my @args   = @{ $inst->{args} };
            my $target = ( $op =~ /_func$/ ) ? shift @args : undef;
            if ( $op =~ /_reg$/ ) {
                my $first_arg = shift @args;
                my $src_reg   = ( $first_arg =~ /^%/ && exists $reg_map->{$first_arg} ) ? $reg_map->{$first_arg} : 'r11';
                $as->mov_reg( 'r11', $src_reg );
            }
            for my $i ( 0 .. $#args ) {
                my $dst = $self->_abi_arg_reg($i);
                my $src = ( $args[$i] =~ /^%/ ) ? $reg_map->{ $args[$i] } : 'r10';
                if ( $args[$i] !~ /^%/ ) {
                    if ( $args[$i] =~ /^[A-Z_]/i ) { $as->lea_rva( 'r10', $args[$i], $driver->text_rva ); }
                    else                           { $as->mov_imm( 'r10', $v->( $args[$i] ) ); }
                }
                if ( $dst =~ /^\d+$/ ) {
                    $as->store_mem_disp_reg( 'rsp', $dst * 8, $src );
                }
                else {
                    $as->mov_reg( $dst, $src ) if $dst ne $src;
                    my $xmm_dst = "xmm$i";
                    $as->movq_reg_xmm( $xmm_dst, $src );    # Keep ABI fully happy
                }
            }
            if ( $op =~ /^tail_call_/ ) {

                # Epilogue before jumping
                $as->add_imm( 'rsp', $driver->frame_local_size );
                for my $r ( reverse @{ $driver->preserved_regs() } ) { $as->pop_reg($r); }
                if   ( $op eq 'tail_call_func' ) { $as->jmp($target); }
                else                             { $as->append_code( pack( 'CCC', 0x41, 0xFF, 0xE3 ) ); }    # jmp r11
            }
            else {
                if   ( $op eq 'call_func' ) { $as->call_label($target); }
                else                        { $as->append_code( pack( 'CCC', 0x41, 0xFF, 0xD3 ) ); }         # call r11
                if ( defined $d_reg ) {
                    if ( $inst->{type} && ( $inst->{type} eq 'double' || $inst->{type} eq 'float' ) ) {
                        $as->movq_xmm_reg( $d_reg, 'xmm0' );
                    }
                    else {
                        $as->mov_reg( $d_reg, 'rax' );
                    }
                }
            }
        }
        elsif ( $op eq 'enter_func' || $op eq 'enter_leaf_func' ) {
            if ( $op eq 'enter_func' ) {
                for my $r ( @{ $driver->preserved_regs() } ) { $as->push_reg($r); }
                $as->mov_reg( 'rbp', 'rsp' );
            }
            else {
                # enter_leaf_func: can omit rbp setup if we don't need it for unwinding/debugging,
                # but for now let's just omit the preserved regs if we are feeling brave.
                # Actually, a leaf function still might use preserved regs if the register
                # allocator assigned them.
                for my $r ( @{ $driver->preserved_regs() } ) { $as->push_reg($r); }
            }
            $as->sub_imm( 'rsp', $driver->frame_local_size );
            if ( $driver->type eq 'shared' && defined $driver->global_iso_offset ) {
                $as->lea_rva( 'r11', "DATA:" . $driver->global_iso_offset );
                $as->load_reg_mem( 'r14', 'r11', 0 );
            }
        }
        elsif ( $op eq 'leave_func' ) {
            if ( defined $inst->{args}[0] ) {
                my $arg  = $inst->{args}[0];
                my $type = $inst->{type} // 'i64';
                if ( $type eq 'double' || $type eq 'float' ) {

                    # Float return goes in XMM0
                    if ( $arg =~ /^%/ ) {
                        $as->movq_reg_xmm( 'xmm0', $reg_map->{$arg} );
                    }
                    else {
                        my $bits = unpack( 'Q<', pack( 'd<', $v->($arg) // 0.0 ) );
                        $as->mov_imm( 'r10', $bits );
                        $as->movq_reg_xmm( 'xmm0', 'r10' );
                    }
                }
                else {
                    # Int return in RAX
                    if ( $arg =~ /^%/ ) { $as->mov_reg( 'rax', $reg_map->{$arg} ); }
                    else                { $as->mov_imm( 'rax', $v->($arg) ); }
                }
            }
            $as->add_imm( 'rsp', $driver->frame_local_size );
            for my $r ( reverse @{ $driver->preserved_regs() } ) { $as->pop_reg($r); }
            $as->append_code( pack( 'C', 0xC3 ) );
        }
        elsif ( $op eq 'shadow_push' ) {
            $as->load_reg_mem( 'r11', 'r14', $driver->iso_offset('current_fcb') );
            $as->load_reg_mem( 'r10', 'r11', $driver->fcb_offset('shadow_ptr') );
            my $src = ( $inst->{args}[0] =~ /^%/ ) ? $reg_map->{ $inst->{args}[0] } : 'r11';
            $as->mov_imm( 'r11', $v->( $inst->{args}[0] ) ) if $inst->{args}[0] !~ /^%/;
            $as->store_mem_disp_reg( 'r10', 0, $src );
            $as->add_imm( 'r10', 8 );
            $as->store_mem_disp_reg( 'r11', $driver->fcb_offset('shadow_ptr'), 'r10' );
        }
        elsif ( $op =~ /^shadow_(get|set|restore)$/ ) {
            $as->load_reg_mem( 'r11', 'r14', $driver->iso_offset('current_fcb') );
            if ( $op eq 'shadow_get' ) { $as->load_reg_mem( $d_reg, 'r11', $driver->fcb_offset('shadow_ptr') ); }
            else {
                my $src = ( $inst->{args}[0] =~ /^%/ ) ? $reg_map->{ $inst->{args}[0] } : 'r10';
                $as->mov_imm( 'r10', $v->( $inst->{args}[0] ) ) if $inst->{args}[0] !~ /^%/;
                $as->store_mem_disp_reg( 'r11', $driver->fcb_offset('shadow_ptr'), $src );
            }
        }

        # Inside Brocken::Target::X64::emit_op
        elsif ( $op eq 'shadow_pop' ) {

            # r14 = Isolate, current_fcb offset is 24, shadow_ptr offset in FCB is 32
            $as->load_reg_mem( 'r11', 'r14', $driver->iso_offset('current_fcb') );
            $as->load_reg_mem( 'r10', 'r11', $driver->fcb_offset('shadow_ptr') );
            $as->sub_imm( 'r10', 8 );
            $as->store_mem_disp_reg( 'r11', $driver->fcb_offset('shadow_ptr'), 'r10' );
        }
        elsif ( $op =~ /^(local|atomic)_(inc|dec)_ref$/ ) {
            my $is_atomic = $1 eq 'atomic';
            my $is_inc    = $2 eq 'inc';
            my $obj       = $reg_map->{ $inst->{args}[0] };

            # RC is at bit 48. Incrementing by 1 << 48 adjusts the RC field.
            $as->mov_imm( 'r11', 1 << 48 );
            $as->lock() if $is_atomic;
            if ($is_inc) { $as->add_mem_disp_reg( $obj, -8, 'r11' ); }
            else         { $as->sub_mem_disp_reg( $obj, -8, 'r11' ); }
        }
        elsif ( $op eq 'get_bp' ) {
            $as->mov_reg( $d_reg, 'rbp' );
        }
        elsif ( $op eq 'load_iso_disp' ) { $as->load_reg_mem( $d_reg, 'r14', $inst->{args}[0] ); }
        elsif ( $op eq 'store_iso_disp' ) {
            my $src = ( $inst->{args}[1] =~ /^%/ ) ? $reg_map->{ $inst->{args}[1] } : 'r11';
            $as->mov_imm( 'r11', $v->( $inst->{args}[1] ) ) if $inst->{args}[1] !~ /^%/;
            $as->store_mem_disp_reg( 'r14', $inst->{args}[0], $src );
        }
        elsif ( $op =~ /^load_(func|data)_addr$/ ) {
            my $trva = $inst->{args}[0];
            if ( $trva =~ /^\d+$/ ) {
                if ( $op eq 'load_data_addr' ) { $as->lea_rva( $d_reg, "DATA:$trva" ); }
                else                           { $as->lea_rva( $d_reg, $trva, $driver->text_rva ); }
            }
            else { $as->lea_rva( $d_reg, $trva ); }
        }
        elsif ( $op eq 'get_isolate_ctx' ) { $as->mov_reg( $d_reg, 'r14' ); }
        elsif ( $op eq 'set_isolate_ctx' ) { $as->mov_reg( 'r14',  $reg_map->{ $inst->{args}[0] } ); }
        elsif ( $op eq 'get_arg' ) {
            my $arg_idx = $inst->{args}[0];
            my $type    = $inst->{type} // 'i64';
            if ( $type eq 'double' || $type eq 'float' ) {
                my $xmm_reg = $self->_abi_fp_arg_reg($arg_idx);
                $as->movq_xmm_reg( $d_reg, $xmm_reg );
            }
            else {
                $as->mov_reg( $d_reg, $self->_abi_arg_reg($arg_idx) );
            }
        }
        elsif ( $op eq 'get_sp' ) { $as->mov_reg( $d_reg, 'rsp' ); }
        elsif ( $op eq 'get_bp' ) { $as->mov_reg( $d_reg, 'rbp' ); }
    }
}

class Brocken::Target::X64::Emit {
    field $code : reader = '';
    field %labels;
    field @fixups;
    method labels() { return \%labels; }

    method reg($r) {
        state $MAP = {
            rax   => 0,
            rcx   => 1,
            rdx   => 2,
            rbx   => 3,
            rsp   => 4,
            rbp   => 5,
            rsi   => 6,
            rdi   => 7,
            r8    => 8,
            r9    => 9,
            r10   => 10,
            r11   => 11,
            r12   => 12,
            r13   => 13,
            r14   => 14,
            r15   => 15,
            xmm0  => 0,
            xmm1  => 1,
            xmm2  => 2,
            xmm3  => 3,
            xmm4  => 4,
            xmm5  => 5,
            xmm6  => 6,
            xmm7  => 7,
            xmm8  => 8,
            xmm9  => 9,
            xmm10 => 10,
            xmm11 => 11,
            xmm12 => 12,
            xmm13 => 13,
            xmm14 => 14,
            xmm15 => 15
        };
        my $name = lc( $r // '' );
        $name =~ s/^\s+|\s+$//g;
        die "Logic Error: Expected X64 register name, got '$r'" unless exists $MAP->{$name};
        return $MAP->{$name};
    }

    method _rex( $w, $ri, $xi, $bi ) {
        my $rex = 0x40;
        $rex |= 0x08 if $w;
        $rex |= 0x04 if ( $ri // 0 ) >= 8;
        $rex |= 0x02 if ( $xi // 0 ) >= 8;
        $rex |= 0x01 if ( $bi // 0 ) >= 8;
        if ( !$w && ( ( ( $ri // 0 ) >= 4 && ( $ri // 0 ) <= 7 ) || ( ( $bi // 0 ) >= 4 && ( $bi // 0 ) <= 7 ) ) ) {
            return pack( 'C', $rex );
        }
        return ( $rex == 0x40 && !$w ) ? '' : pack( 'C', $rex );
    }


        method _emit_modrm( $opcode, $reg_name, $base_name, $disp, $w = 1, $prefix = '' ) {
            my $ri  = $self->reg($reg_name);
            my $bi  = $self->reg($base_name);
            my $mod = ( $disp == 0 && ( $bi & 7 ) != 5 ) ? 0 : ( $disp >= -128 && $disp <= 127 ? 1 : 2 );
            $code
                .= $self->_rex( $w, $ri, 0, $bi ) . $prefix . pack( 'C', $opcode ) . pack( 'C', ( $mod << 6 ) | ( ( $ri & 7 ) << 3 ) | ( $bi & 7 ) );
            $code .= pack( 'C', 0x24 ) if ( ( $bi & 7 ) == 4 );
            if    ( $mod == 1 )                                      { $code .= pack( 'c',  $disp ); }
            elsif ( $mod == 2 || ( $mod == 0 && ( $bi & 7 ) == 5 ) ) { $code .= pack( 'l<', $disp ); }
        }
    method append_code($bin) { $code .= $bin }
    method mark_label($n)    { $labels{$n} = length $code }
    method lock()            { $code .= pack( 'C', 0xF0 ) }

    method mov_reg( $d, $s ) {
        my $di = $self->reg($d);
        my $si = $self->reg($s);
        $code .= $self->_rex( 1, $si, 0, $di ) . pack( 'CC', 0x89, 0xC0 | ( ( $si & 7 ) << 3 ) | ( $di & 7 ) );
    }

    method mov_imm( $r, $imm ) {
        my $ri = $self->reg($r);
        $code .= $self->_rex( 1, 0, 0, $ri ) . pack( 'Cq<', 0xB8 + ( $ri & 7 ), $imm );
    }

    method push_reg($r) {
        my $ri = $self->reg($r);
        if ( $ri >= 8 ) { $code .= pack( 'CC', 0x41, 0x50 | ( $ri & 7 ) ); }
        else            { $code .= pack( 'C', 0x50 | $ri ); }
    }

    method pop_reg($r) {
        my $ri = $self->reg($r);
        if ( $ri >= 8 ) { $code .= pack( 'CC', 0x41, 0x58 | ( $ri & 7 ) ); }
        else            { $code .= pack( 'C', 0x58 | $ri ); }
    }
    method add_imm( $r, $i ) { my $ri = $self->reg($r); $code .= $self->_rex( 1, 0, 0, $ri ) . pack( 'CCl<', 0x81, 0xC0 | ( $ri & 7 ), $i ); }
    method sub_imm( $r, $i ) { my $ri = $self->reg($r); $code .= $self->_rex( 1, 0, 0, $ri ) . pack( 'CCl<', 0x81, 0xE8 | ( $ri & 7 ), $i ); }
    method and_imm( $r, $i ) { my $ri = $self->reg($r); $code .= $self->_rex( 1, 0, 0, $ri ) . pack( 'CCl<', 0x81, 0xE0 | ( $ri & 7 ), $i ); }
    method or_imm( $r, $i )  { my $ri = $self->reg($r); $code .= $self->_rex( 1, 0, 0, $ri ) . pack( 'CCl<', 0x81, 0xC8 | ( $ri & 7 ), $i ); }
    method xor_imm( $r, $i ) { my $ri = $self->reg($r); $code .= $self->_rex( 1, 0, 0, $ri ) . pack( 'CCl<', 0x81, 0xF0 | ( $ri & 7 ), $i ); }

    method add_reg( $d, $s ) {
        $code .= $self->_rex( 1, $self->reg($s), 0, $self->reg($d) ) .
            pack( 'CC', 0x01, 0xC0 | ( ( $self->reg($s) & 7 ) << 3 ) | ( $self->reg($d) & 7 ) );
    }

    method sub_reg( $d, $s ) {
        $code .= $self->_rex( 1, $self->reg($s), 0, $self->reg($d) ) .
            pack( 'CC', 0x29, 0xC0 | ( ( $self->reg($s) & 7 ) << 3 ) | ( $self->reg($d) & 7 ) );
    }

    method mul_reg( $d, $s ) {
        $code .= $self->_rex( 1, $self->reg($d), 0, $self->reg($s) ) .
            pack( 'CCC', 0x0F, 0xAF, 0xC0 | ( ( $self->reg($d) & 7 ) << 3 ) | ( $self->reg($s) & 7 ) );
    }

    method and_reg( $d, $s ) {
        $code .= $self->_rex( 1, $self->reg($s), 0, $self->reg($d) ) .
            pack( 'CC', 0x21, 0xC0 | ( ( $self->reg($s) & 7 ) << 3 ) | ( $self->reg($d) & 7 ) );
    }

    method or_reg( $d, $s ) {
        $code .= $self->_rex( 1, $self->reg($s), 0, $self->reg($d) ) .
            pack( 'CC', 0x09, 0xC0 | ( ( $self->reg($s) & 7 ) << 3 ) | ( $self->reg($d) & 7 ) );
    }

    method xor_reg( $d, $s ) {
        $code .= $self->_rex( 1, $self->reg($s), 0, $self->reg($d) ) .
            pack( 'CC', 0x31, 0xC0 | ( ( $self->reg($s) & 7 ) << 3 ) | ( $self->reg($d) & 7 ) );
    }
    method idiv_reg($src) { $code .= $self->_rex( 1, 0, 0, $self->reg($src) ) . pack( 'CC', 0xF7, 0xF8 | ( $self->reg($src) & 7 ) ); }

    method shl_imm( $r, $i ) {
        my $ri = $self->reg($r);
        $code .= $self->_rex( 1, 0, 0, $ri ) . pack( 'CCC', 0xC1, 0xE0 | ( $ri & 7 ), $i & 0xFF );
    }

    method shr_imm( $r, $i ) {
        my $ri = $self->reg($r);
        $code .= $self->_rex( 1, 0, 0, $ri ) . pack( 'CCC', 0xC1, 0xE8 | ( $ri & 7 ), $i & 0xFF );
    }
    method shl_cl($r) { my $ri = $self->reg($r); $code .= $self->_rex( 1, 0, 0, $ri ) . pack( 'CC', 0xD3, 0xE0 | ( $ri & 7 ) ); }
    method shr_cl($r) { my $ri = $self->reg($r); $code .= $self->_rex( 1, 0, 0, $ri ) . pack( 'CC', 0xD3, 0xE8 | ( $ri & 7 ) ); }

    method cmp_reg_reg( $l, $r ) {
        $code .= $self->_rex( 1, $self->reg($r), 0, $self->reg($l) ) .
            pack( 'CC', 0x39, 0xC0 | ( ( $self->reg($r) & 7 ) << 3 ) | ( $self->reg($l) & 7 ) );
    }
    method cmp_reg_imm( $r, $i )    { $code .= $self->_rex( 1, 0, 0, $self->reg($r) ) . pack( 'CCl<', 0x81, 0xF8 | ( $self->reg($r) & 7 ), $i ); }
    method cmp_reg_imm_32( $r, $i ) { $code .= $self->_rex( 0, 0, 0, $self->reg($r) ) . pack( 'CCl<', 0x81, 0xF8 | ( $self->reg($r) & 7 ), $i ); }

    method test_reg_reg( $l, $r ) {
        $code .= $self->_rex( 1, $self->reg($r), 0, $self->reg($l) ) .
            pack( 'CC', 0x85, 0xC0 | ( ( $self->reg($r) & 7 ) << 3 ) | ( $self->reg($l) & 7 ) );
    }

    method setcc( $cc, $r ) {
        my $ri = $self->reg($r);
        $code .= pack( 'C', 0x40 | ( $ri >= 8 ? 1 : 0 ) ) . pack( 'CCC', 0x0F, $cc, 0xC0 | ( $ri & 7 ) );
    }
    method store_mem_disp_byte( $b, $d, $s )      { $self->_emit_modrm( 0x88, $s, $b, $d, 0 ); }
    method store_mem_disp_reg( $b, $d, $s )       { $self->_emit_modrm( 0x89, $s, $b, $d, 1 ); }
    method load_reg_mem( $d, $s, $off = 0 )       { $self->_emit_modrm( 0x8B, $d, $s, $off, 1 ); }
    method load_reg_mem_byte( $d, $s, $off = 0 )  { $self->_emit_modrm( 0xB6, $d, $s, $off, 1, pack( 'C', 0x0F ) ); }
    method lea_reg_disp( $d, $b, $off )           { $self->_emit_modrm( 0x8D, $d, $b, $off, 1 ); }
    method add_mem_disp_reg( $b, $d, $s, $w = 1 ) { $self->_emit_modrm( 0x01, $s, $b, $d, $w ); }
    method sub_mem_disp_reg( $b, $d, $s, $w = 1 ) { $self->_emit_modrm( 0x29, $s, $b, $d, $w ); }

    method lea_rva( $reg, $target, $txtrva = 0 ) {
        my $ri = $self->reg($reg);
        if ( $target =~ /^([A-Z_]|DATA:|TEXT:)/i ) {
            $code .= $self->_rex( 1, $ri, 0, 0 ) . pack( 'CC', 0x8D, 0x05 | ( ( $ri & 7 ) << 3 ) );
            push @fixups, { offset => length($code), target => $target };
            $code .= pack( 'L<', 0 );
        }
        else {
            my $next = $txtrva + length($code) + 7;
            $code .= $self->_rex( 1, $ri, 0, 0 ) . pack( 'CC l<', 0x8D, 0x05 | ( ( $ri & 7 ) << 3 ), $target - $next );
        }
    }

    method call_rva( $trva, $txtrva ) {
        my $next = $txtrva + length($code) + 6;
        $code .= pack( 'CC l<', 0xFF, 0x15, $trva - $next );
    }
    method call_label($l) { $code .= pack( 'C', 0xE8 ); push @fixups, { offset => length($code), target => $l }; $code .= pack( 'L<', 0 ); }
    method call_reg($r)   { $code .= $self->_rex( 0, 0, 0, $self->reg($r) ) . pack( 'C', 0xFF ) . pack( 'C', 0xD0 + $self->reg($r) ); }
    method jmp_reg($r)    { $code .= $self->_rex( 0, 0, 0, $self->reg($r) ) . pack( 'C', 0xFF ) . pack( 'C', 0xE0 + ( $self->reg($r) & 7 ) ); }
    method jmp($l)        { $code .= pack( 'C', 0xE9 ); push @fixups, { offset => length($code), target => $l }; $code .= pack( 'L<', 0 ); }

    method jcc( $cc, $l ) {
        $code .= pack( 'CC', 0x0F, 0x80 + $cc );
        push @fixups, { offset => length($code), target => $l };
        $code .= pack( 'L<', 0 );
    }
    method syscall { $code .= pack 'CC', 0x0F, 0x05 }

    # SSE2 Floating Point Instructions
    method addsd_reg( $d, $s ) {
        $code
            .= pack( 'C', 0xF2 ) .
            $self->_rex( 0, $self->reg($s), 0, $self->reg($d) ) .
            pack( 'CC', 0x0F, 0x58 ) .
            pack( 'C', 0xC0 | ( ( $self->reg($s) & 7 ) << 3 ) | ( $self->reg($d) & 7 ) );
    }

    method subsd_reg( $d, $s ) {
        $code
            .= pack( 'C', 0xF2 ) .
            $self->_rex( 0, $self->reg($s), 0, $self->reg($d) ) .
            pack( 'CC', 0x0F, 0x5C ) .
            pack( 'C', 0xC0 | ( ( $self->reg($s) & 7 ) << 3 ) | ( $self->reg($d) & 7 ) );
    }

    method mulsd_reg( $d, $s ) {
        $code
            .= pack( 'C', 0xF2 ) .
            $self->_rex( 0, $self->reg($s), 0, $self->reg($d) ) .
            pack( 'CC', 0x0F, 0x59 ) .
            pack( 'C', 0xC0 | ( ( $self->reg($s) & 7 ) << 3 ) | ( $self->reg($d) & 7 ) );
    }

    method divsd_reg( $d, $s ) {
        $code
            .= pack( 'C', 0xF2 ) .
            $self->_rex( 0, $self->reg($s), 0, $self->reg($d) ) .
            pack( 'CC', 0x0F, 0x5E ) .
            pack( 'C', 0xC0 | ( ( $self->reg($s) & 7 ) << 3 ) | ( $self->reg($d) & 7 ) );
    }

    method ucomisd_reg( $d, $s ) {
        $code
            .= pack( 'C', 0x66 ) .
            $self->_rex( 0, $self->reg($d), 0, $self->reg($s) ) .
            pack( 'CC', 0x0F, 0x2E ) .
            pack( 'C', 0xC0 | ( ( $self->reg($d) & 7 ) << 3 ) | ( $self->reg($s) & 7 ) );
    }

    method movq_reg_xmm( $d, $s ) {

        # 66 0F 6E /r - Move QWORD (from GP to XMM)
        $code
            .= pack( 'C', 0x66 ) .
            $self->_rex( 1, $self->reg($d), 0, $self->reg($s) ) .
            pack( 'CC', 0x0F, 0x6E ) .
            pack( 'C', 0xC0 | ( ( $self->reg($d) & 7 ) << 3 ) | ( $self->reg($s) & 7 ) );
    }

    method movq_xmm_reg( $d, $s ) {

        # 66 0F 7E /r - Move QWORD (from XMM to GP)
        $code
            .= pack( 'C', 0x66 ) .
            $self->_rex( 1, $self->reg($s), 0, $self->reg($d) ) .
            pack( 'CC', 0x0F, 0x7E ) .
            pack( 'C', 0xC0 | ( ( $self->reg($s) & 7 ) << 3 ) | ( $self->reg($d) & 7 ) );
    }

    method resolve( $text_rva = 0, $data_rva = 0 ) {
        for (@fixups) {
            my $target = $_->{target};
            my $t;
            if ( $target =~ /^DATA:(\d+)$/ ) {
                $t = $1 + $data_rva - $text_rva;
            }
            elsif ( $target =~ /^TEXT:(\d+)$/ ) {
                $t = $1;
            }
            else {
                $t = $labels{$target};
                die "Linker Error: Unresolved label '$target'\n" unless defined $t;
            }
            substr( $code, $_->{offset}, 4, pack( 'l<', $t - ( $_->{offset} + 4 ) ) );
        }
    }
}

1;
__END__

=pod

=head1 NAME

Brocken::Target::X64 - x64 CPU target implementation

=head1 SYNOPSIS

    my $target = Brocken::Target::X64->new( os => 'linux', arch => 'x64' );
    my @regs = @{ $target->registers };
    $target->emit_op($as, $inst, \%reg_map, $compiler);

=head1 DESCRIPTION

Implements the L<Brocken::Target> interface for the x86_64 architecture. Handles the mapping of Brocken IR to x64
machine code, manages the x64 register pool, and implements System V and Windows x64 ABIs.

=head1 METHODS

=head2 registers

Returns the list of available callee-saved general-purpose registers (excluding R14 which is reserved for Isolate
context).

=head2 fp_registers

Returns the list of available XMM registers for floating-point operations.

=head2 compile_intrinsic($as, $inst, $reg_map, $driver)

Delegates intrinsic compilation to the current platform module.

=head2 new_assembler

Returns a new L<Brocken::Target::X64::Emit> instance.

=head2 emit_op($as, $inst, $reg_map, $driver)

The core code generation loop. Translates a single IR instruction into one or more x64 machine instructions.

=cut
