package Brocken::Target::ARM64 {
    use v5.40;
    use feature 'class';
    no warnings 'experimental::class';

    class Brocken::Target::ARM64 : isa(Brocken::Target) {

        method registers() {

            # Callee-saved registers x19-x27 (x28 reserved for isolate context)
            return [qw(x19 x20 x21 x22 x23 x24 x25 x26 x27)];
        }

        method _abi_arg_reg($idx) {
            return (qw[x0 x1 x2 x3 x4 x5 x6 x7])[$idx] // 'stack';
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
            elsif ( $op eq 'constant' ) { $as->mov_imm( $d_reg, $inst->{args}[0] ); }
            elsif ( $op eq 'mov' ) {
                my $s = $v->( $inst->{args}[0] );
                if ( $inst->{args}[0] =~ /^%/ || $inst->{args}[0] =~ /^[a-z]/i ) { $as->mov_reg( $d_reg, $s ) if ( $d_reg // '' ) ne ( $s // '' ); }
                else                                                             { $as->mov_imm( $d_reg, $s ); }
            }
            elsif ( $op =~ /^(add|sub|mul)$/ ) {
                my $lv = $v->( $inst->{args}[0] );
                my $rv = $v->( $inst->{args}[1] );

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

                my $ln = ( $inst->{args}[0] =~ /^%/ ) ? $lv : 'x16';
                $as->mov_imm( 'x16', $lv ) if $inst->{args}[0] !~ /^%/;

                $inst->{args}[1] =~ /^%/ ? $as->cmp_reg_reg( $ln, $reg_map->{ $inst->{args}[1] } ) : $as->cmp_reg_imm( $ln, $rv );
                $as->setcc( $driver->cc($type), $d_reg );
            }
            elsif ( $op =~ /^(shl|shr)$/ ) {
                my $val = $v->( $inst->{args}[0] );
                my $amt = $inst->{args}[1];

                my $ln = ( $inst->{args}[0] =~ /^%/ ) ? $val : 'x16';
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
                $as->mov_imm( 'x16', $val ) if $inst->{args}[1] !~ /^%/;
                my $off = -$inst->{args}[0];
                if ( $off < 0 || $off % 8 != 0 ) { $as->stur_mem_disp_reg( 'x29', $off, $src ); }
                else                            { $as->store_mem_disp_reg( 'x29', $off, $src ); }
            }
            elsif ( $op eq 'local_load' ) {
                my $off = -$inst->{args}[0];
                if ( $off < 0 || $off % 8 != 0 ) { $as->ldur_reg_mem( $d_reg, 'x29', $off ); }
                else                            { $as->load_reg_mem( $d_reg, 'x29', $off ); }
            }
            elsif ( $op eq 'load_mem_disp' ) {
                my $off = $inst->{args}[1];
                if ( $off < 0 || $off % 8 != 0 ) { $as->ldur_reg_mem( $d_reg, $reg_map->{ $inst->{args}[0] }, $off ); }
                else                            { $as->load_reg_mem( $d_reg, $reg_map->{ $inst->{args}[0] }, $off ); }
            }
            elsif ( $op eq 'store_mem_disp' ) {
                my $src = ( $inst->{args}[2] =~ /^%/ ) ? $reg_map->{ $inst->{args}[2] } : 'x16';
                $as->mov_imm( 'x16', $v->( $inst->{args}[2] ) ) if $inst->{args}[2] !~ /^%/;
                my $off = $inst->{args}[1];
                if ( $off < 0 || $off % 8 != 0 ) { $as->stur_mem_disp_reg( $reg_map->{ $inst->{args}[0] }, $off, $src ); }
                else                            { $as->store_mem_disp_reg( $reg_map->{ $inst->{args}[0] }, $off, $src ); }
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
                    else           { $as->load_reg_mem_byte( $d_reg, $base, $idx ); }
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
                    else           { $as->store_mem_disp_byte( $base, $idx, $src ); }
                }
            }
            elsif ( $op eq 'load_iso_disp' ) {
                my $off = $inst->{args}[0];
                if ( $off < 0 || $off % 8 != 0 ) { $as->ldur_reg_mem( $d_reg, 'x28', $off ); }
                else                            { $as->load_reg_mem( $d_reg, 'x28', $off ); }
            }
            elsif ( $op eq 'store_iso_disp' ) {
                my $src = ( $inst->{args}[1] =~ /^%/ ) ? $reg_map->{ $inst->{args}[1] } : 'x16';
                $as->mov_imm( 'x16', $v->( $inst->{args}[1] ) ) if $inst->{args}[1] !~ /^%/;
                my $off = $inst->{args}[0];
                if ( $off < 0 || $off % 8 != 0 ) { $as->stur_mem_disp_reg( 'x28', $off, $src ); }
                else                            { $as->store_mem_disp_reg( 'x28', $off, $src ); }
            }
            elsif ( $op eq 'load_func_addr' || $op eq 'load_data_addr' ) {
                my $target = $inst->{args}[0];
                if ( $target =~ /^\d+$/ ) {
                    my $base = ( $op eq 'load_data_addr' ) ? $driver->data_rva : 0;
                    $as->lea_rva( $d_reg, $base + $target, $driver->text_rva );
                }
                else { $as->lea_rva( $d_reg, $target, $driver->text_rva ); }
            }
            elsif ( $op eq 'get_arg' )         { $as->mov_reg( $d_reg, $self->_abi_arg_reg( $inst->{args}[0] ) ); }
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
                if ( defined $rv ) { $inst->{args}[0] =~ /^%/ ? $as->mov_reg( 'x0', $reg_map->{ $inst->{args}[0] } ) : $as->mov_imm( 'x0', $rv ); }
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
                else                        { $as->append_code( pack( 'L<', 0xD63F0200 ) ); } # blr x16
                $as->mov_reg( $d_reg, 'x0' ) if defined $d_reg;
            }
            elsif ( $op eq 'get_sp' ) { $as->mov_reg( $d_reg, 'sp' ); }
            elsif ( $op eq 'map_op' ) {
                $as->mov_imm( $d_reg, 1 ) if defined $d_reg;
            }
            # ... shadow stack ops omitted for brevity or I should add them
            elsif ( $op =~ /^shadow_/ ) {
                # Add shadow stack support for ARM64 if needed. 
                # For now, let's just use x28 for isolate context and follow X64 pattern.
                if ($op eq 'shadow_push') {
                    my $val = $v->( $inst->{args}[0] );
                    $as->ldur_reg_mem( 'x15', 'x28', $driver->iso_offset('current_fcb') );
                    $as->ldur_reg_mem( 'x17', 'x15', $driver->fcb_offset('shadow_ptr') );
                    if ( $inst->{args}[0] =~ /^%/ ) { $as->stur_mem_disp_reg( 'x17', 0, $reg_map->{ $inst->{args}[0] } ); }
                    else                            { $as->mov_imm( 'x16', $val ); $as->stur_mem_disp_reg( 'x17', 0, 'x16' ); }
                    $as->add_imm( 'x17', 8 );
                    $as->stur_mem_disp_reg( 'x15', $driver->fcb_offset('shadow_ptr'), 'x17' );
                }
                elsif ($op eq 'shadow_get') {
                    $as->ldur_reg_mem( 'x16',  'x28', $driver->iso_offset('current_fcb') );
                    $as->ldur_reg_mem( $d_reg, 'x16', $driver->fcb_offset('shadow_ptr') );
                }
                elsif ($op =~ /^shadow_(set|restore)$/) {
                    $as->ldur_reg_mem( 'x16', 'x28', $driver->iso_offset('current_fcb') );
                    $as->stur_mem_disp_reg( 'x16', $driver->fcb_offset('shadow_ptr'), $v->( $inst->{args}[0] ) );
                }
            }
        }

        method compile_intrinsic( $as, $inst, $reg_map, $driver ) {
            return $driver->platform->emit_intrinsic( $self, $as, $inst, $reg_map, $driver );
        }
    }
}
1;
