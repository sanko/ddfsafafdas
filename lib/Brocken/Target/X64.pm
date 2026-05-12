package Brocken::Target::X64 {
    use v5.40;
    use feature 'class';
    no warnings 'experimental::class';

    class Brocken::Target::X64 : isa(Brocken::Target) {

        method registers() {
            return $self->os eq 'win64' ? [qw(rbx rsi rdi r12 r13 r15)] : [qw(rbx r12 r13 r15)];
        }

        method _abi_arg_reg($idx) {
            if   ( $self->os eq 'win64' ) { return (qw[rcx rdx r8 r9])[$idx]         // $idx; }
            else                          { return (qw[rdi rsi rdx rcx r8 r9])[$idx] // $idx; }
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
                my $s_raw = $inst->{args}[0];
                if ( $s_raw =~ /^%/ || $s_raw =~ /^[a-z]/i ) {
                    my $s_reg = $v->($s_raw);
                    $as->mov_reg( $d_reg, $s_reg ) if ( $d_reg // '' ) ne ( $s_reg // '' );
                }
                else { $as->mov_imm( $d_reg, $v->($s_raw) ); }
            }
            elsif ( $op =~ /^(add|sub|mul|and|or|xor)$/ ) {
                my ( $l_raw, $r_raw ) = @{ $inst->{args} };
                my ( $lv,    $rv )    = ( $v->($l_raw), $v->($r_raw) );
                if ( $l_raw =~ /^%/ ) {
                    if ( $r_raw =~ /^%/ && $d_reg eq $reg_map->{$r_raw} && $d_reg ne $lv ) {
                        $as->mov_reg( 'r11',  $reg_map->{$r_raw} );
                        $as->mov_reg( $d_reg, $lv );
                        $rv = 'r11';
                    }
                    else { $as->mov_reg( $d_reg, $lv ) if $d_reg ne $lv; }
                }
                else { $as->mov_imm( $d_reg, $lv ); }
                if ( $r_raw =~ /^%/ || $rv eq 'r11' ) {
                    my $rs = ( $rv eq 'r11' ) ? 'r11' : $reg_map->{$r_raw};
                    if    ( $op eq 'add' ) { $as->add_reg( $d_reg, $rs ); }
                    elsif ( $op eq 'sub' ) { $as->sub_reg( $d_reg, $rs ); }
                    elsif ( $op eq 'and' ) { $as->and_reg( $d_reg, $rs ); }
                    elsif ( $op eq 'or' )  { $as->or_reg( $d_reg, $rs ); }
                    elsif ( $op eq 'xor' ) { $as->xor_reg( $d_reg, $rs ); }
                    else                   { $as->mul_reg( $d_reg, $rs ); }
                }
                else {
                    if    ( $op eq 'add' ) { $as->add_imm( $d_reg, $rv ); }
                    elsif ( $op eq 'sub' ) { $as->sub_imm( $d_reg, $rv ); }
                    elsif ( $op eq 'and' ) { $as->and_imm( $d_reg, $rv ); }
                    elsif ( $op eq 'or' )  { $as->or_imm( $d_reg, $rv ); }
                    elsif ( $op eq 'xor' ) { $as->xor_imm( $d_reg, $rv ); }
                    else                   { $as->mov_imm( 'r11', $rv ); $as->mul_reg( $d_reg, 'r11' ); }
                }
            }
            elsif ( $op =~ /^(div|mod)$/ ) {
                $as->push_reg('rdx');
                if ( $inst->{args}[0] =~ /^%/ ) { $as->mov_reg( 'rax', $v->( $inst->{args}[0] ) ); }
                else                            { $as->mov_imm( 'rax', $v->( $inst->{args}[0] ) ); }
                $as->append_code( pack( 'CC', 0x48, 0x99 ) );
                if   ( $inst->{args}[1] =~ /^%/ ) { $as->idiv_reg( $reg_map->{ $inst->{args}[1] } ); }
                else                              { $as->mov_imm( 'r11', $v->( $inst->{args}[1] ) ); $as->idiv_reg('r11'); }
                my $res_phys = ( $op eq 'div' ? 'rax' : 'rdx' );
                $as->mov_reg( 'r10', $res_phys );
                $as->pop_reg('rdx');
                $as->mov_reg( $d_reg, 'r10' );
            }
            elsif ( $op =~ /^cmp_(eq|ne|lt|gt|le|ge)$/ ) {
                my $type = $1;
                my ( $l_raw, $r_raw ) = @{ $inst->{args} };
                my ( $lv, $rv )       = ( $v->($l_raw), $v->($r_raw) );
                my $l_reg = $lv;
                if   ( $l_raw !~ /^%/ ) { $as->mov_imm( 'r10', $lv ); $l_reg = 'r10'; }
                if   ( $r_raw =~ /^%/ ) { $as->cmp_reg_reg( $l_reg, $reg_map->{$r_raw} ); }
                else                    { $as->cmp_reg_imm( $l_reg, $rv ); }
                $as->mov_imm( $d_reg, 0 );
                my $cc_map = { eq => 0x94, ne => 0x95, lt => 0x9C, ge => 0x9D, le => 0x9E, gt => 0x9F };
                $as->setcc( $cc_map->{$type}, $d_reg );
            }
            elsif ( $op eq 'local_store' ) {
                my $src_raw = $inst->{args}[1];
                if ( $src_raw !~ /^%/ ) { $as->mov_imm( 'r11', $v->($src_raw) ); $as->store_mem_disp_reg( 'rbp', -$inst->{args}[0], 'r11' ); }
                else                    { $as->store_mem_disp_reg( 'rbp', -$inst->{args}[0], $reg_map->{$src_raw} ); }
            }
            elsif ( $op eq 'local_load' )    { $as->load_reg_mem( $d_reg, 'rbp',                          -$inst->{args}[0] ); }
            elsif ( $op eq 'load_mem_disp' ) { $as->load_reg_mem( $d_reg, $reg_map->{ $inst->{args}[0] }, $inst->{args}[1] ); }
            elsif ( $op eq 'store_mem_disp' ) {
                my $src_raw = $inst->{args}[2];
                if ( $src_raw !~ /^%/ ) {
                    $as->mov_imm( 'r11', $v->($src_raw) );
                    $as->store_mem_disp_reg( $reg_map->{ $inst->{args}[0] }, $inst->{args}[1], 'r11' );
                }
                else { $as->store_mem_disp_reg( $reg_map->{ $inst->{args}[0] }, $inst->{args}[1], $reg_map->{$src_raw} ); }
            }
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
            elsif ( $op =~ /^call_(func|reg)$/ ) {
                my @args   = @{ $inst->{args} };
                my $target = ( $op eq 'call_func' ) ? shift @args : $reg_map->{ shift @args };
                $as->mov_reg( 'r11', $target ) if $op eq 'call_reg';
                for my $i ( 0 .. $#args ) {
                    my $arg   = $args[$i];
                    my $dst   = $self->_abi_arg_reg($i);
                    my $src_v = ( $arg =~ /^%/ ) ? $reg_map->{$arg} : 'r10';
                    if ( $arg !~ /^%/ ) {
                        if ( $arg =~ /^[A-Z_]/i ) { $as->lea_rva( 'r10', $arg, $driver->text_rva ); }
                        else                      { $as->mov_imm( 'r10', $v->($arg) ); }
                    }
                    if ( $dst =~ /^\d+$/ ) {
                        my $off = ( $self->os eq 'win64' ) ? ( $dst * 8 ) : ( ( $dst - 6 ) * 8 );
                        $as->store_mem_disp_reg( 'rsp', $off, $src_v );
                    }
                    else { $as->mov_reg( $dst, $src_v ) if $dst ne $src_v; }
                }
                if   ( $op eq 'call_func' ) { $as->call_label($target); }
                else                        { $as->append_code( pack( 'CCC', 0x41, 0xFF, 0xD3 ) ); }
                $as->mov_reg( $d_reg, 'rax' ) if defined $d_reg;
            }
            elsif ( $op eq 'enter_func' ) {
                for my $r ( @{ $driver->preserved_regs() } ) { $as->push_reg($r); }
                $as->mov_reg( 'rbp', 'rsp' );
                $as->sub_imm( 'rsp', $driver->frame_local_size );
            }
            elsif ( $op eq 'leave_func' ) {
                my $rv = $v->( $inst->{args}[0] );
                if ( defined $rv ) {
                    if ( $inst->{args}[0] =~ /^%/ ) { $as->mov_reg( 'rax', $reg_map->{ $inst->{args}[0] } ); }
                    else                            { $as->mov_imm( 'rax', $rv ); }
                }
                $as->add_imm( 'rsp', $driver->frame_local_size );
                for my $r ( reverse @{ $driver->preserved_regs() } ) { $as->pop_reg($r); }
                $as->append_code( pack( 'C', 0xC3 ) );
            }
            elsif ( $op eq 'shadow_push' ) {
                $as->load_reg_mem( 'r11', 'r14', $driver->iso_offset('current_fcb') );
                $as->load_reg_mem( 'r10', 'r11', $driver->fcb_offset('shadow_ptr') );
                my $src_raw = $inst->{args}[0];
                my $src_reg;
                if ( $src_raw =~ /^%/ ) {
                    $src_reg = $reg_map->{$src_raw};
                }
                else {
                    $as->mov_imm( 'r11', $v->($src_raw) );
                    $src_reg = 'r11';
                }
                $as->store_mem_disp_reg( 'r10', 0, $src_reg );
                $as->add_imm( 'r10', 8 );

                # Reload FCB because WinAPI calls (if any) could have clobbered r11
                $as->load_reg_mem( 'r11', 'r14', $driver->iso_offset('current_fcb') );
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
                my $src = $inst->{args}[1];
                if ( $src !~ /^%/ ) { $as->mov_imm( 'r11', $v->($src) ); $as->store_mem_disp_reg( 'r14', $inst->{args}[0], 'r11' ); }
                else                { $as->store_mem_disp_reg( 'r14', $inst->{args}[0], $reg_map->{$src} ); }
            }
            elsif ( $op =~ /^load_(func|data)_addr$/ ) {
                my $trva = $inst->{args}[0];
                if ( $trva =~ /^\d+$/ ) { $trva += ( $op eq 'load_data_addr' ? $driver->data_rva : 0 ); }
                $as->lea_rva( $d_reg, $trva, $driver->text_rva );
            }
            elsif ( $op eq 'get_isolate_ctx' ) { $as->mov_reg( $d_reg, 'r14' ); }
            elsif ( $op eq 'set_isolate_ctx' ) { $as->mov_reg( 'r14',  $reg_map->{ $inst->{args}[0] } ); }
            elsif ( $op eq 'get_arg' )         { $as->mov_reg( $d_reg, $self->_abi_arg_reg( $inst->{args}[0] ) ); }
            elsif ( $op eq 'get_sp' )          { $as->mov_reg( $d_reg, 'rsp' ); }
            elsif ( $op eq 'map_op' )          { $as->mov_imm( $d_reg, 1 ) if defined $d_reg; }
        }

        method compile_intrinsic( $as, $inst, $reg_map, $driver ) {
            return $driver->platform->emit_intrinsic( $self, $as, $inst, $reg_map, $driver );
        }
    }
}
1;
