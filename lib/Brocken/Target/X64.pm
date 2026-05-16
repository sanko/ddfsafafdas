package Brocken::Target::X64 {
    use v5.40;
    use feature 'class';
    no warnings 'experimental::class';

    class Brocken::Target::X64 : isa(Brocken::Target) {

        method registers() {

            # Reserve R14 for Isolate and R10/R11 for internal compiler use
            return $self->os eq 'win64' ? [qw(rbx rsi rdi r12 r13 r15)] : [qw(rbx r12 r13 r15)];
        }

        method _abi_arg_reg($idx) {
            if   ( $self->os eq 'win64' ) { return (qw[rcx rdx r8 r9])[$idx]         // $idx; }
            else                          { return (qw[rdi rsi rdx rcx r8 r9])[$idx] // $idx; }
        }

        method compile_intrinsic( $as, $inst, $reg_map, $driver ) {
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
            elsif ( $op eq 'constant' ) { $as->mov_imm( $d_reg, $inst->{args}[0] ); }
            elsif ( $op eq 'mov' ) {
                my $src = $inst->{args}[0];
                if ( $src =~ /^%/ ) { $as->mov_reg( $d_reg, $reg_map->{$src} ) if $d_reg ne $reg_map->{$src}; }
                else                { $as->mov_imm( $d_reg, $v->($src) ); }
            }
            elsif ( $op =~ /^(add|sub|mul|and|or|xor)$/ ) {
                my ( $l_raw, $r_raw ) = @{ $inst->{args} };
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
                    if    ( $op eq 'add' ) { $as->add_imm( $d_reg, $v->($r_raw) ) }
                    elsif ( $op eq 'sub' ) { $as->sub_imm( $d_reg, $v->($r_raw) ) }
                    elsif ( $op eq 'and' ) { $as->and_imm( $d_reg, $v->($r_raw) ) }
                    elsif ( $op eq 'or' )  { $as->or_imm( $d_reg, $v->($r_raw) ) }
                    elsif ( $op eq 'xor' ) { $as->xor_imm( $d_reg, $v->($r_raw) ) }
                    else                   { $as->mov_imm( 'r11', $v->($r_raw) ); $as->mul_reg( $d_reg, 'r11' ); }
                }
            }
            elsif ( $op =~ /^(div|mod)$/ ) {
                $as->push_reg('rdx');
                $as->push_reg('rax');
                if ( $inst->{args}[0] =~ /^%/ ) { $as->mov_reg( 'rax', $reg_map->{ $inst->{args}[0] } ); }
                else                            { $as->mov_imm( 'rax', $v->( $inst->{args}[0] ) ); }
                $as->append_code( pack( 'CC', 0x48, 0x99 ) );
                if   ( $inst->{args}[1] =~ /^%/ ) { $as->idiv_reg( $reg_map->{ $inst->{args}[1] } ); }
                else                              { $as->mov_imm( 'r11', $v->( $inst->{args}[1] ) ); $as->idiv_reg('r11'); }
                $as->mov_reg( 'r10', ( $op eq 'div' ? 'rax' : 'rdx' ) );
                $as->pop_reg('rax');
                $as->pop_reg('rdx');
                $as->mov_reg( $d_reg, 'r10' );
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
                my $l_reg = ( $l_raw =~ /^%/ ) ? $reg_map->{$l_raw} : 'r10';
                $as->mov_imm( 'r10', $v->($l_raw) ) if $l_raw !~ /^%/;
                if ( $r_raw =~ /^%/ ) { $as->cmp_reg_reg( $l_reg, $reg_map->{$r_raw} ); }
                else                  { $as->cmp_reg_imm( $l_reg, $v->($r_raw) ); }
                $as->mov_imm( $d_reg, 0 );
                my $cc = { eq => 0x94, ne => 0x95, lt => 0x9C, gt => 0x9F, le => 0x9E, ge => 0x9D }->{ substr( $op, 4 ) };
                $as->setcc( $cc, $d_reg );
            }
            elsif ( $op eq 'local_store' ) {
                my $src = $inst->{args}[1];
                if ( $src !~ /^%/ ) { $as->mov_imm( 'r11', $v->($src) ); $as->store_mem_disp_reg( 'rbp', -$inst->{args}[0], 'r11' ); }
                else                { $as->store_mem_disp_reg( 'rbp', -$inst->{args}[0], $reg_map->{$src} ); }
            }
            elsif ( $op eq 'local_load' ) { $as->load_reg_mem( $d_reg, 'rbp', -$inst->{args}[0] ); }
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
            elsif ( $op =~ /^call_/ ) {
                my @args   = @{ $inst->{args} };
                my $target = ( $op eq 'call_func' ) ? shift @args : $reg_map->{ shift @args };
                $as->mov_reg( 'r11', $target ) if $op eq 'call_reg';
                for my $i ( 0 .. $#args ) {
                    my $dst = $self->_abi_arg_reg($i);
                    my $src = ( $args[$i] =~ /^%/ ) ? $reg_map->{ $args[$i] } : 'r10';
                    if ( $args[$i] !~ /^%/ ) {
                        if ( $args[$i] =~ /^[A-Z_]/i ) { $as->lea_rva( 'r10', $args[$i], $driver->text_rva ); }
                        else                           { $as->mov_imm( 'r10', $v->( $args[$i] ) ); }
                    }
                    if ( $dst =~ /^\d+$/ ) { $as->store_mem_disp_reg( 'rsp', $dst * 8, $src ); }
                    else                   { $as->mov_reg( $dst, $src ) if $dst ne $src; }
                }
                if   ( $op eq 'call_func' ) { $as->call_label($target); }
                else                        { $as->append_code( pack( 'CCC', 0x41, 0xFF, 0xD3 ) ); }
                $as->mov_reg( $d_reg, 'rax' ) if defined $d_reg;
            }
            elsif ( $op eq 'enter_func' ) {
                for my $r ( @{ $driver->preserved_regs() } ) { $as->push_reg($r); }
                $as->mov_reg( 'rbp', 'rsp' );
                $as->sub_imm( 'rsp', $driver->frame_local_size );

                # In shared libraries, we must reload R14 from the global Isolate pointer
                # because the caller (Perl/C) won't have it set up.
                if ( $driver->type eq 'shared' && defined $driver->global_iso_offset ) {
                    $as->lea_rva( 'r11', "DATA:" . $driver->global_iso_offset );
                    $as->load_reg_mem( 'r14', 'r11', 0 );
                }
            }
            elsif ( $op eq 'leave_func' ) {
                if ( defined $inst->{args}[0] ) {
                    if ( $inst->{args}[0] =~ /^%/ ) { $as->mov_reg( 'rax', $reg_map->{ $inst->{args}[0] } ); }
                    else                            { $as->mov_imm( 'rax', $v->( $inst->{args}[0] ) ); }
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
            elsif ( $op eq 'load_iso_disp' ) { $as->load_reg_mem( $d_reg, 'r14', $inst->{args}[0] ); }
            elsif ( $op eq 'store_iso_disp' ) {
                my $src = ( $inst->{args}[1] =~ /^%/ ) ? $reg_map->{ $inst->{args}[1] } : 'r11';
                $as->mov_imm( 'r11', $v->( $inst->{args}[1] ) ) if $inst->{args}[1] !~ /^%/;
                $as->store_mem_disp_reg( 'r14', $inst->{args}[0], $src );
            }
            elsif ( $op =~ /^load_(func|data)_addr$/ ) {
                my $trva = $inst->{args}[0];
                if ( $trva =~ /^\d+$/ ) {
                    if ( $op eq 'load_data_addr' ) {
                        $as->lea_rva( $d_reg, "DATA:$trva" );
                    }
                    else {
                        # Absolute text address (e.g. for JIT)
                        $as->lea_rva( $d_reg, $trva, $driver->text_rva );
                    }
                }
                else {
                    $as->lea_rva( $d_reg, $trva );
                }
            }
            elsif ( $op eq 'get_isolate_ctx' ) { $as->mov_reg( $d_reg, 'r14' ); }
            elsif ( $op eq 'set_isolate_ctx' ) { $as->mov_reg( 'r14',  $reg_map->{ $inst->{args}[0] } ); }
            elsif ( $op eq 'get_arg' )         { $as->mov_reg( $d_reg, $self->_abi_arg_reg( $inst->{args}[0] ) ); }
            elsif ( $op eq 'get_sp' )          { $as->mov_reg( $d_reg, 'rsp' ); }
        }
    }
}
1;
