package Brocken::Codegen {
    use v5.40;
    use utf8;
    use feature 'class';
    no warnings 'portable', 'experimental::class';

    class Brocken::Codegen {
        field $arch : param;

        method _abi_max_args($os) {
            return 4 if $arch eq 'arm64';
            return $os eq 'win64' ? 4 : 6;
        }

        method _abi_arg_reg( $idx, $os ) {
            if ( $arch eq 'arm64' ) { return 'x' . $idx; }
            else {
                if   ( $os eq 'win64' ) { return (qw[rcx rdx r8 r9])[$idx]         // 'stack'; }
                else                    { return (qw[rdi rsi rdx rcx r8 r9])[$idx] // 'stack'; }
            }
        }

        method compile( $instructions, $driver ) {
            my $as = $driver->as;

            # The allocator will now inject SPILL loads/stores into $instructions if needed
            my %reg_map = $self->_allocate_registers( $instructions, $driver );

            my $val = sub {
                my $arg = shift;
                return undef unless defined $arg;
                return $reg_map{$arg} if defined $arg && $arg =~ /^%/;
                return $arg;
            };

            for my $inst (@$instructions) {
                my $op = $inst->{op};
                if    ( $op eq 'label' ) { $as->mark_label( $inst->{name} ); }
                elsif ( $op eq 'jmp' )   { $as->jmp( $inst->{target} ); }
                elsif ( $op eq 'cond_br' ) {
                    my $reg = $val->( $inst->{reg} );
                    $as->test_reg_reg( $reg, $reg );
                    $as->jcc( $driver->cc('nz'), $inst->{true_l} );
                    $as->jmp( $inst->{false_l} );
                }
                elsif ( $op eq 'constant' ) { $as->mov_imm( $reg_map{ $inst->{dest} }, $inst->{args}[0] ); }
                elsif ( $op eq 'load_data_addr' || $op eq 'load_func_addr' ) {
                    my $target = $inst->{args}[0];
                    if ( $target =~ /^\d+$/ ) {
                        my $base = ( $op eq 'load_data_addr' ) ? $driver->data_rva : 0;
                        $as->lea_rva( $reg_map{ $inst->{dest} }, $base + $target, $driver->text_rva );
                    } else { $as->lea_rva( $reg_map{ $inst->{dest} }, $target, $driver->text_rva ); }
                }
                elsif ( $op eq 'mov' ) {
                    my $d = $reg_map{ $inst->{dest} };
                    my $s = $val->( $inst->{args}[0] ) // $inst->{args}[0];
                    if ( $inst->{args}[0] =~ /^%/ || $inst->{args}[0] =~ /^[a-z]/i ) { $as->mov_reg( $d, $s ) if $d ne $s; }
                    else { $as->mov_imm( $d, $s ); }
                }
                elsif ( $op eq 'local_store' ) {
                    my $v = $val->( $inst->{args}[1] );
                    if ( $arch eq 'x64' ) {
                        if ( $inst->{args}[1] !~ /^%/ ) { $as->mov_imm( 'r11', $v ); $as->store_mem_disp_reg( 'rbp', -$inst->{args}[0], 'r11' ); }
                        else { $as->store_mem_disp_reg( 'rbp', -$inst->{args}[0], $v ); }
                    } else {
                        my $src = ( $inst->{args}[1] =~ /^%/ ) ? $v : 'x16';
                        $as->mov_imm( 'x16', $v ) if $inst->{args}[1] !~ /^%/;
                        $as->sub_imm( 'x17', $inst->{args}[0] );
                        $as->add_reg( 'x17', 'x29' );
                        $as->store_mem_disp_reg( 'x17', 0, $src );
                    }
                }
                elsif ( $op eq 'local_load' ) {
                    if ( $arch eq 'x64' ) { $as->load_reg_mem( $reg_map{ $inst->{dest} }, 'rbp', -$inst->{args}[0] ); }
                    else {
                        $as->sub_imm( 'x17', $inst->{args}[0] );
                        $as->add_reg( 'x17', 'x29' );
                        $as->load_reg_mem( $reg_map{ $inst->{dest} }, 'x17', 0 );
                    }
                }
                elsif ( $op =~ /^(and|or)$/ ) {
                    my $d = $reg_map{ $inst->{dest} }; my $lv = $val->( $inst->{args}[0] ); my $rv = $val->( $inst->{args}[1] );
                    $as->mov_reg( $d, $lv ) if $d ne $lv;
                    my $si = ( $inst->{args}[1] =~ /^%/ ) ? $reg_map{ $inst->{args}[1] } : 'r11';
                    $as->mov_imm( 'r11', $rv ) if $inst->{args}[1] !~ /^%/;
                    my $di_idx = $as->reg($d); my $si_idx = $as->reg($si);
                    $as->append_code( pack( 'CCCC', 0x48 | ( $si_idx >= 8 ? 4 : 0 ) | ( $di_idx >= 8 ? 1 : 0 ), ( $op eq 'and' ? 0x21 : 0x09 ), 0xC0 | ( ( $si_idx & 7 ) << 3 ) | ( $di_idx & 7 ) ) );
                }
                elsif ( $op =~ /^(add|sub|mul)$/ ) {
                    my $d = $reg_map{ $inst->{dest} }; my $lv = $val->( $inst->{args}[0] ); my $rv = $val->( $inst->{args}[1] );
                    $as->mov_reg( $d, $lv ) if $d ne $lv;
                    if ( $inst->{args}[1] =~ /^%/ ) {
                        if ( $op eq 'add' ) { $as->add_reg( $d, $reg_map{ $inst->{args}[1] } ); }
                        elsif ( $op eq 'sub' ) { $as->sub_reg( $d, $reg_map{ $inst->{args}[1] } ); }
                        else { $as->mul_reg( $d, $reg_map{ $inst->{args}[1] } ); }
                    } else {
                        if ( $op eq 'add' ) { $as->add_imm( $d, $rv ); }
                        elsif ( $op eq 'sub' ) { $as->sub_imm( $d, $rv ); }
                        else { $as->mov_imm( 'r11', $rv ); $as->mul_reg( $d, 'r11' ); }
                    }
                }
                elsif ( $op =~ /^(div|mod)$/ ) {
                    my $d = $reg_map{ $inst->{dest} }; my $lv = $val->( $inst->{args}[0] ); my $rv = $val->( $inst->{args}[1] );
                    $as->mov_reg( 'rax', $lv ); $as->append_code( pack( 'CC', 0x48, 0x99 ) );
                    if ( $inst->{args}[1] =~ /^%/ ) { $as->idiv_reg( $reg_map{ $inst->{args}[1] } ); }
                    else { $as->mov_imm( 'r11', $rv ); $as->idiv_reg('r11'); }
                    $as->mov_reg( $d, ( $op eq 'div' ? 'rax' : 'rdx' ) );
                }
                elsif ( $op =~ /^cmp_(eq|ne|lt|gt|le|ge)$/ ) {
                    my $type = $1; my $d = $reg_map{ $inst->{dest} }; my $lv = $val->( $inst->{args}[0] ); my $rv = $val->( $inst->{args}[1] );
                    if ( $inst->{args}[1] =~ /^%/ ) { $as->cmp_reg_reg( $lv, $reg_map{ $inst->{args}[1] } ); }
                    else { $as->cmp_reg_imm( $lv, $rv ); }
                    $as->mov_imm( $d, 0 );
                    my $cc_map = { eq => 0x94, ne => 0x95, lt => 0x9C, ge => 0x9D, le => 0x9E, gt => 0x9F };
                    $as->setcc( $cc_map->{$type}, $d );
                }
                elsif ( $op eq 'builtin_print' ) {
                    my $p = $reg_map{ $inst->{args}[0] };
                    if ( $driver->os eq 'win64' ) {
                        $as->mov_imm( 'rcx', -11 ); $as->call_rva( $driver->import_rva('GetStdHandle'), $driver->text_rva );
                        $as->mov_reg( 'rcx', 'rax' ); $as->mov_reg( 'rdx', $p ); $as->add_imm( 'rdx', 24 );
                        $as->load_reg_mem( 'r8', $p, 0 ); $as->lea_reg_disp( 'r9', 'rsp', 40 );
                        $as->mov_imm( 'rax', 0 ); $as->store_mem_disp_reg( 'rsp', 32, 'rax' );
                        $as->call_rva( $driver->import_rva('WriteFile'), $driver->text_rva );
                    } else {
                        $as->mov_reg( 'rsi', $p ); $as->load_reg_mem( 'rdx', 'rsi', 0 ); $as->add_imm( 'rsi', 24 );
                        $as->mov_imm( 'rdi', 1 ); $as->mov_imm( 'rax', ( $driver->os eq 'macos' ? 0x2000004 : 1 ) ); $as->syscall();
                    }
                }
                elsif ( $op eq 'builtin_print_char' ) {
                    my $char = $val->( $inst->{args}[0] );
                    my $src_reg = ( $inst->{args}[0] =~ /^%/ ) ? $reg_map{ $inst->{args}[0] } : 'r11';
                    $as->mov_imm( 'r11', $char ) if $inst->{args}[0] !~ /^%/;
                    $as->store_mem_disp_byte( 'rsp', 48, $src_reg );
                    if ( $driver->os eq 'win64' ) {
                        $as->mov_imm( 'rcx', -11 ); $as->call_rva( $driver->import_rva('GetStdHandle'), $driver->text_rva );
                        $as->mov_reg( 'rcx', 'rax' ); $as->lea_reg_disp( 'rdx', 'rsp', 48 ); $as->mov_imm( 'r8', 1 );
                        $as->lea_reg_disp( 'r9', 'rsp', 40 ); $as->mov_imm( 'rax', 0 );
                        $as->store_mem_disp_reg( 'rsp', 32, 'rax' );
                        $as->call_rva( $driver->import_rva('WriteFile'), $driver->text_rva );
                    } else {
                        $as->mov_imm( 'rax', ( $driver->os eq 'macos' ? 0x2000004 : 1 ) ); $as->mov_imm( 'rdi', 1 );
                        $as->lea_reg_disp( 'rsi', 'rsp', 48 ); $as->mov_imm( 'rdx', 1 ); $as->syscall();
                    }
                }
                elsif ( $op eq 'setup_page_fault_handler' ) {
                    if ( $driver->os eq 'win64' ) {
                        $as->mov_imm( 'rcx', 1 );
                        $as->lea_rva( 'rdx', 'M_veh_handler', $driver->text_rva );
                        $as->call_rva( $driver->import_rva('AddVectoredExceptionHandler'), $driver->text_rva );
                    } else {
                        $as->lea_rva( 'r11', 'M_segv_handler', $driver->text_rva );
                        $as->store_mem_disp_reg( 'rsp', 32, 'r11' );
                        $as->mov_imm( 'r11', 4 ); $as->store_mem_disp_reg( 'rsp', 40, 'r11' );
                        $as->mov_imm( 'r11', 0 ); $as->store_mem_disp_reg( 'rsp', 48, 'r11' );
                        $as->mov_imm( 'rax', 13 ); $as->mov_imm( 'rdi', 11 );
                        $as->lea_reg_disp( 'rsi', 'rsp', 32 ); $as->mov_imm( 'rdx', 0 );
                        $as->mov_imm( 'r10', 8 ); $as->syscall();
                    }
                }
                elsif ( $op eq 'setup_console' ) {
                    if ( $driver->os eq 'win64' ) {
                        $as->mov_imm( 'rcx', 65001 );
                        $as->call_rva( $driver->import_rva('SetConsoleOutputCP'), $driver->text_rva );
                    }
                }
                elsif ( $op eq 'exit_program' ) {
                    my $v = $val->( $inst->{args}[0] ); my $target = ( $arch eq 'x64' ? 'rdi' : 'x0' );
                    if ( $inst->{args}[0] =~ /^%/ ) { $as->mov_reg( $target, $reg_map{ $inst->{args}[0] } ) if $target ne $reg_map{ $inst->{args}[0] }; }
                    else { $as->mov_imm( $target, $v // 0 ); }
                    if ( $driver->os eq 'win64' ) { $as->mov_reg( 'rcx', $target ); $as->call_rva( $driver->import_rva('ExitProcess'), $driver->text_rva ); }
                    else { $driver->exit_reg($target); $as->append_code( pack( 'CC', 0x0F, 0x0B ) ); }
                }
                elsif ( $op eq 'shadow_push' ) {
                    my $v = $val->( $inst->{args}[0] ); my $iso = ( $arch eq 'x64' ? 'r14' : 'x27' );
                    $as->load_reg_mem( 'r11', $iso,  $driver->iso_offset('current_fcb') );
                    $as->load_reg_mem( 'rax', 'r11', $driver->fcb_offset('shadow_ptr') );
                    if ( $inst->{args}[0] =~ /^%/ ) { $as->store_mem_disp_reg( 'rax', 0, $reg_map{ $inst->{args}[0] } ); }
                    else { $as->mov_imm( 'r11', $v ); $as->store_mem_disp_reg( 'rax', 0, 'r11' ); }
                    $as->add_imm( 'rax', 8 ); $as->load_reg_mem( 'r11', $iso, $driver->iso_offset('current_fcb') );
                    $as->store_mem_disp_reg( 'r11', $driver->fcb_offset('shadow_ptr'), 'rax' );
                }
                elsif ( $op eq 'call_reg' ) {
                    my @args = @{ $inst->{args} }[ 1 .. $#{ $inst->{args} } ]; $as->mov_reg( 'r11', $reg_map{ $inst->{args}[0] } );
                    for my $i ( 0 .. $#args ) {
                        my $arg = $args[$i]; my $dst_abi = $self->_abi_arg_reg( $i, $driver->os );
                        if ( $arg =~ /^%/ ) { $as->mov_reg( $dst_abi, $reg_map{$arg} ); }
                        elsif ( $arg =~ /^[A-Z_]/i ) { $as->lea_rva( $dst_abi, $arg, $driver->text_rva ); }
                        else { $as->mov_imm( $dst_abi, $arg ); }
                    }
                    $as->append_code( pack( 'CCC', 0x41, 0xFF, 0xD3 ) );
                    if ( defined $inst->{dest} ) { $as->mov_reg( $reg_map{ $inst->{dest} }, 'rax' ); }
                }
                elsif ( $op eq 'load_mem_disp' ) { $as->load_reg_mem( $reg_map{ $inst->{dest} }, $reg_map{ $inst->{args}[0] }, $inst->{args}[1] ); }
                elsif ( $op eq 'store_mem_disp' ) { $as->store_mem_disp_reg( $reg_map{ $inst->{args}[0] }, $inst->{args}[1], $val->( $inst->{args}[2] ) ); }
                elsif ( $op eq 'load_mem_byte' ) {
                    my $d = $reg_map{ $inst->{dest} }; my $base = $reg_map{ $inst->{args}[0] }; my $idx = $inst->{args}[1];
                    if ( $idx =~ /^%/ ) { $as->mov_reg( 'r11', $base ); $as->add_reg( 'r11', $reg_map{$idx} ); $as->load_reg_mem_byte( $d, 'r11', 0 ); }
                    else { $as->load_reg_mem_byte( $d, $base, $idx ); }
                }
                elsif ( $op eq 'store_mem_byte' ) {
                    my $base = $reg_map{ $inst->{args}[0] }; my $idx = $inst->{args}[1]; my $src_reg = ( $inst->{args}[2] =~ /^%/ ) ? $reg_map{ $inst->{args}[2] } : 'r11';
                    $as->mov_imm( 'r11', $val->( $inst->{args}[2] ) ) if $inst->{args}[2] !~ /^%/;
                    if ( $idx =~ /^%/ ) { $as->push_reg('rax'); $as->mov_reg( 'rax', $base ); $as->add_reg( 'rax', $reg_map{$idx} ); $as->store_mem_disp_byte( 'rax', 0, $src_reg ); $as->pop_reg('rax'); }
                    else { $as->store_mem_disp_byte( $base, $idx, $src_reg ); }
                }
                elsif ( $op eq 'load_iso_disp' ) { $as->load_reg_mem( $reg_map{ $inst->{dest} }, ( $arch eq 'x64' ? 'r14' : 'x27' ), $inst->{args}[0] ); }
                elsif ( $op eq 'store_iso_disp' ) { $as->store_mem_disp_reg( ( $arch eq 'x64' ? 'r14' : 'x27' ), $inst->{args}[0], $val->( $inst->{args}[1] ) ); }
                elsif ( $op eq 'get_arg' ) { $as->mov_reg( $reg_map{ $inst->{dest} }, $self->_abi_arg_reg( $inst->{args}[0], $driver->os ) ); }
                elsif ( $op eq 'set_isolate_ctx' ) { $as->mov_reg( ( $arch eq 'x64' ? 'r14' : 'x27' ), $reg_map{ $inst->{args}[0] } ); }
                elsif ( $op eq 'get_isolate_ctx' ) { $as->mov_reg( $reg_map{ $inst->{dest} }, ( $arch eq 'x64' ? 'r14' : 'x27' ) ); }
                elsif ( $op eq 'enter_func' ) {
                    my $regs = $driver->preserved_regs();
                    if ( $arch eq 'x64' ) {
                        for my $r (@$regs) { $as->push_reg($r); }
                        $as->mov_reg( 'rbp', 'rsp' ); $as->sub_imm( 'rsp', $driver->frame_local_size );
                    } else {
                        $as->push_reg('x29'); $as->push_reg('x30');
                        $as->mov_reg( 'x29', 'sp' ); $as->sub_imm( 'sp', 160 );
                    }
                }
                elsif ( $op eq 'leave_func' ) {
                    my $rv = $val->( $inst->{args}[0] );
                    if ( defined $rv ) {
                        if ( $inst->{args}[0] =~ /^%/ ) {
                            if ( $arch eq 'x64' ) { $as->mov_reg( 'rax', $reg_map{ $inst->{args}[0] } ) if $reg_map{ $inst->{args}[0] } ne 'rax'; }
                            else { $as->mov_reg( 'x0', $reg_map{ $inst->{args}[0] } ) if $reg_map{ $inst->{args}[0] } ne 'x0'; }
                        } else {
                            if ( $arch eq 'x64' ) { $as->mov_imm( 'rax', $rv ); }
                            else { $as->mov_imm( 'x0', $rv ); }
                        }
                    }
                    if ( $arch eq 'x64' ) {
                        $as->add_imm( 'rsp', $driver->frame_local_size );
                        my $regs = $driver->preserved_regs();
                        for my $r ( reverse @$regs ) { $as->pop_reg($r); }
                        $as->append_code( pack( 'C', 0xC3 ) );
                    } else {
                        $as->add_imm( 'sp', 160 ); $as->pop_reg('x30'); $as->pop_reg('x29');
                        $as->append_code( pack( 'L<', 0xD65F03C0 ) );
                    }
                }
                elsif ( $op eq 'call_func' ) {
                    my $target = $inst->{args}[0]; my $dest = $reg_map{ $inst->{dest} } if defined $inst->{dest};
                    my @args = @{ $inst->{args} }[ 1 .. $#{ $inst->{args} } ];
                    for my $i ( 0 .. $#args ) {
                        my $arg = $args[$i]; my $dst_abi = $self->_abi_arg_reg( $i, $driver->os );
                        if ( $arg =~ /^%/ ) { $as->mov_reg( $dst_abi, $reg_map{$arg} ); }
                        elsif ( $arg =~ /^[A-Z_]/i ) { $as->lea_rva( $dst_abi, $arg, $driver->text_rva ); }
                        else { $as->mov_imm( $dst_abi, $arg ); }
                    }
                    $as->call_label($target);
                    if ( defined $dest ) { $as->mov_reg( $dest, 'rax' ); }
                }
                elsif ( $op eq 'sys_alloc' ) {
                    my $d = $reg_map{ $inst->{dest} }; my $sz = $val->( $inst->{args}[0] );
                    if ( $driver->os eq 'win64' ) {
                        $as->mov_imm( 'rcx', 0 ); if ( $inst->{args}[0] =~ /^%/ ) { $as->mov_reg( 'rdx', $reg_map{ $inst->{args}[0] } ); }
                        else { $as->mov_imm( 'rdx', $sz ); }
                        $as->mov_imm( 'r8', 0x3000 ); $as->mov_imm( 'r9', 0x04 );
                        $as->call_rva( $driver->import_rva('VirtualAlloc'), $driver->text_rva );
                        $as->mov_reg( $d, 'rax' );
                    } else {
                        $as->mov_imm( 'rax', 9 ); $as->mov_imm( 'rdi', 0 );
                        if ( $inst->{args}[0] =~ /^%/ ) { $as->mov_reg( 'rsi', $reg_map{ $inst->{args}[0] } ); }
                        else { $as->mov_imm( 'rsi', $sz ); }
                        $as->mov_imm( 'rdx', 3 );
                        $as->mov_imm( 'r10', 0x22 );
                        $as->mov_imm( 'r8', -1 );
                        $as->mov_imm( 'r9', 0 );
                        $as->syscall(); $as->mov_reg( $d, 'rax' );
                    }
                }
                elsif ( $op eq 'emit_native_handlers' ) {
                    if ( $driver->os eq 'win64' ) {
                        $as->mark_label('M_veh_handler'); $as->load_reg_mem( 'rax', 'rcx', 0 );
                        $as->append_code( pack( 'CCC', 0x44, 0x8B, 0x18 ) ); $as->cmp_reg_imm_32( 'r11', 0xC0000005 );
                        $as->jcc( 5, 'veh_not_handled' ); $as->load_reg_mem( 'r8', 'rax', 40 ); $as->mov_imm( 'r11', -4096 );
                        $as->append_code( pack( 'CCC', 0x4D, 0x21, 0xD8 ) ); $as->sub_imm( 'rsp', 40 ); $as->mov_reg( 'rcx', 'r8' );
                        $as->mov_imm( 'rdx', 4096 ); $as->mov_imm( 'r8', 0x1000 ); $as->mov_imm( 'r9', 4 );
                        $as->call_rva( $driver->import_rva('VirtualAlloc'), $driver->text_rva ); $as->add_imm( 'rsp', 40 );
                        $as->cmp_reg_imm( 'rax', 0 ); $as->jcc( 4, 'veh_not_handled' ); $as->mov_imm( 'rax', -1 ); $as->append_code( pack( 'C', 0xC3 ) );
                        $as->mark_label('veh_not_handled'); $as->mov_imm( 'rax', 0 ); $as->append_code( pack( 'C', 0xC3 ) );
                    } else {
                        $as->mark_label('M_segv_handler'); $as->load_reg_mem( 'rdi', 'rsi', 16 );
                        $as->mov_imm( 'r11', -4096 ); $as->append_code( pack( 'CCC', 0x48, 0x21, 0xDF ) );
                        $as->mov_imm( 'rsi', 4096 ); $as->mov_imm( 'rdx', 3 ); $as->mov_imm( 'rax', 10 ); $as->syscall();
                        $as->mov_imm( 'rax', 15 ); $as->syscall();
                    }
                    $as->mark_label('M_fiber_switch');
                    my $regs = $driver->preserved_regs(); my $iso_reg = ( $arch eq 'x64' ? 'r14' : 'x27' );
                    if ( $arch eq 'x64' ) {
                        for my $r (@$regs) { $as->push_reg($r); }
                        if ( $driver->os eq 'win64' ) {
                            $as->mov_reg( 'rax', 'rdx' ); # result value
                            $as->mov_reg( 'r10', 'rcx' ); # target FCB
                        }
                        else {
                            $as->mov_reg( 'rax', 'rsi' ); # result value
                            $as->mov_reg( 'r10', 'rdi' ); # target FCB
                        }
                        # Save current state
                        $as->load_reg_mem( 'r11', $iso_reg, $driver->iso_offset('current_fcb') );
                        $as->store_mem_disp_reg( 'r11', $driver->fcb_offset('sp'), 'rsp' );
                        # Update Isolate to new Fiber
                        $as->store_mem_disp_reg( 'r10', $driver->fcb_offset('caller'), 'r11' );
                        $as->store_mem_disp_reg( $iso_reg, $driver->iso_offset('current_fcb'), 'r10' );
                        # Restore new state
                        $as->load_reg_mem( 'rsp', 'r10', $driver->fcb_offset('sp') );
                        for my $r ( reverse @$regs ) { $as->pop_reg($r); }
                        $as->append_code( pack( 'C', 0xC3 ) ); # rax contains result
                    }
                }
                elsif ( $op eq 'map_op' ) { }
                else { warn 'Unhandled op: ' . $op; }
            }
        }

        method _analyze_liveness($insts) {
            my %live;
            for ( my $i = 0; $i < @$insts; $i++ ) {
                my $ins = $insts->[$i];
                if ( defined $ins->{dest} && $ins->{dest} =~ /^%/ ) { $live{ $ins->{dest} }{start} //= $i; $live{ $ins->{dest} }{end} = $i; }
                if ( $ins->{op} eq 'cond_br' && defined $ins->{reg} ) { $live{ $ins->{reg} }{end} = $i; }
                if ( defined $ins->{args} ) {
                    for my $arg ( @{ $ins->{args} } ) { if ( defined $arg && !ref($arg) && $arg =~ /^%/ ) { $live{$arg}{start} //= $i; $live{$arg}{end} = $i; } }
                }
            }
            my %label_pos;
            for ( my $i = 0; $i < @$insts; $i++ ) { if ( $insts->[$i]{op} eq 'label' ) { $label_pos{ $insts->[$i]{name} } = $i; } }
            for ( my $i = 0; $i < @$insts; $i++ ) {
                my $ins = $insts->[$i]; my $target = $ins->{target} // $ins->{true_l} // $ins->{false_l};
                if ( defined $target && exists $label_pos{$target} ) {
                    my $tpos = $label_pos{$target};
                    if ( $tpos < $i ) {
                        for my $r ( keys %live ) { if ( $live{$r}{start} <= $tpos && $live{$r}{end} >= $tpos ) { $live{$r}{end} = $i if $i > $live{$r}{end}; } }
                    }
                }
            }
            return %live;
        }

        # Automatically insert loads and stores for spilled variables to lower register pressure
        method _spill_vreg($insts, $vreg, $driver) {
            my $slot = $driver->alloc_local_slot();
            my @new_insts;
            my $spill_idx = int(rand(100000));

            for my $orig_inst (@$insts) {
                my %inst = %$orig_inst;
                $inst{args} =[ @{$orig_inst->{args}} ] if defined $orig_inst->{args};

                my $needs_load = 0;
                my $load_reg;

                if ( defined $inst{args} ) {
                    for my $i ( 0 .. $#{ $inst{args} } ) {
                        if ( defined $inst{args}[$i] && !ref($inst{args}[$i]) && $inst{args}[$i] eq $vreg ) {
                            if (!$needs_load) {
                                $needs_load = 1;
                                $load_reg = "%S" . ++$spill_idx;
                            }
                            $inst{args}[$i] = $load_reg;
                        }
                    }
                }
                if ( $inst{op} eq 'cond_br' && defined $inst{reg} && $inst{reg} eq $vreg ) {
                    if (!$needs_load) {
                        $needs_load = 1;
                        $load_reg = "%S" . ++$spill_idx;
                    }
                    $inst{reg} = $load_reg;
                }

                if ($needs_load) {
                    push @new_insts, { op => 'local_load', dest => $load_reg, type => 'i64', args => [$slot] };
                }

                my $needs_store = 0;
                my $store_reg;
                if ( defined $inst{dest} && $inst{dest} eq $vreg ) {
                    $needs_store = 1;
                    $store_reg = "%S" . ++$spill_idx;
                    $inst{dest} = $store_reg;
                }

                push @new_insts, \%inst;

                if ($needs_store) {
                    push @new_insts, { op => 'local_store', type => 'void', args =>[$slot, $store_reg] };
                }
            }
            @$insts = @new_insts;
        }

        method _allocate_registers( $instructions, $driver ) {
            my $changed = 1;
            my %rmap;
            my $max_spills = 100;

            while ($changed && $max_spills-- > 0) {
                $changed = 0;
                my %live = $self->_analyze_liveness($instructions);
                %rmap = ();
                my @free;
                if ( $arch eq 'arm64' ) { @free = qw(x19 x20 x21 x22 x23 x24 x25 x26); }
                else {
                    # r10/r11/r14 are reserved for context switching/isolates/addressing
                    if ( $driver->os eq 'win64' ) { @free = qw(rbx rsi rdi r12 r13 r15); }
                    else { @free = qw(rbx r12 r13 r15); }
                }
                my @intervals = sort { ( $a->{start} // 0 ) <=> ( $b->{start} // 0 ) } map { { vreg => $_, %{ $live{$_} } } } keys %live;
                my @active;

                for my $iv (@intervals) {
                    @active = grep { if ( $_->{end} < ( $iv->{start} // 0 ) ) { push @free, $_->{phys}; 0; } else { 1; } } @active;
                    my $phys = shift @free;

                    if ( !defined $phys ) {
                        # SPILL REQUIRED!
                        @active = sort { $b->{end} <=> $a->{end} } @active;
                        my $spill_vreg;

                        # Find the variable that is active the longest
                        if ($active[0]->{end} > $iv->{end}) {
                            $spill_vreg = $active[0]->{vreg};
                        } else {
                            $spill_vreg = $iv->{vreg};
                        }

                        $self->_spill_vreg($instructions, $spill_vreg, $driver);
                        $changed = 1;
                        last; # Break and restart allocation
                    }
                    $rmap{ $iv->{vreg} } = $phys;
                    push @active, { vreg => $iv->{vreg}, phys => $phys, end => $iv->{end} };
                    @active = sort { $a->{end} <=> $b->{end} } @active;
                }
            }
            die "Register allocator infinite loop! Too many concurrent operands." if $max_spills <= 0;
            return %rmap;
        }
    }
}
1;
