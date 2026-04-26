package Brocken::Codegen {
    use v5.40;
    use utf8;
    use feature 'class';
    no warnings 'portable', 'experimental::class';

    class Brocken::Codegen {
        field $arch : param;

        method _abi_arg_reg( $idx, $os ) {
            if ( $arch eq 'arm64' ) { return 'x' . $idx; }
            else {
                if ( $os eq 'win64' ) {
                    return (qw[rcx rdx r8 r9])[$idx] // die 'Too many args for Win64 ABI at index ' . $idx;
                }
                else {
                    return (qw[rdi rsi rdx rcx r8 r9])[$idx] // die 'Too many args for SysV ABI at index ' . $idx;
                }
            }
        }

        method compile( $instructions, $driver ) {
            my $as       = $driver->as;
            my %liveness = $self->_analyze_liveness($instructions);
            my %reg_map  = $self->_allocate_registers( \%liveness, $driver );
            my $val      = sub {
                my $arg = shift;
                return undef unless defined $arg;
                return $reg_map{$arg} if $arg =~ /^%/;
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
                elsif ( $op eq 'constant' ) {
                    $as->mov_imm( $reg_map{ $inst->{dest} }, $inst->{args}[0] );
                }
                elsif ( $op eq 'load_data_addr' ) {
                    my $target = $inst->{args}[0];
                    if ( $target =~ /^[A-Z_]/i ) { $as->lea_rva( $reg_map{ $inst->{dest} }, $target, $driver->text_rva ); }
                    else { $as->lea_rva( $reg_map{ $inst->{dest} }, $driver->data_rva + $target, $driver->text_rva ); }
                }
                elsif ( $op eq 'mov' ) {
                    my $d = $reg_map{ $inst->{dest} };
                    my $s = $inst->{args}[0];
                    if ( $s =~ /^%/ ) { $as->mov_reg( $d, $reg_map{$s} ) if $d ne $reg_map{$s}; }
                    else              { $as->mov_imm( $d, $s ); }
                }
                elsif ( $op eq 'local_store' ) {
                    my $val_reg = $val->( $inst->{args}[1] );
                    if ( $inst->{args}[1] !~ /^%/ ) {
                        $as->mov_imm( 'r11', $val_reg );
                        $as->store_mem_disp_reg( 'rbp', -$inst->{args}[0], 'r11' );
                    }
                    else { $as->store_mem_disp_reg( 'rbp', -$inst->{args}[0], $val_reg ); }
                }
                elsif ( $op eq 'local_load' ) { $as->load_reg_mem( $reg_map{ $inst->{dest} }, 'rbp', -$inst->{args}[0] ); }
                elsif ( $op eq 'and' ) {
                    my $d  = $reg_map{ $inst->{dest} }; my $lv = $val->( $inst->{args}[0] ); my $rv = $val->( $inst->{args}[1] );
                    $as->mov_reg( $d, $lv ) if $d ne $lv;
                    my $si;
                    if ( $inst->{args}[1] =~ /^%/ ) { $si = $as->reg($rv); }
                    else { $as->mov_imm( 'r11', $rv ); $si = $as->reg('r11'); }
                    my $di  = $as->reg($d); my $rex = 0x48;
                    $rex |= 0x04 if $si >= 8; $rex |= 0x01 if $di >= 8;
                    $as->append_code( pack( 'CCCC', $rex, 0x21, 0xC0 | ( ( $si & 7 ) << 3 ) | ( $di & 7 ) ) );
                }
                elsif ( $op eq 'or' ) {
                    my $d  = $reg_map{ $inst->{dest} }; my $lv = $val->( $inst->{args}[0] ); my $rv = $val->( $inst->{args}[1] );
                    $as->mov_reg( $d, $lv ) if $d ne $lv;
                    my $si;
                    if ( $inst->{args}[1] =~ /^%/ ) { $si = $as->reg($rv); }
                    else { $as->mov_imm( 'r11', $rv ); $si = $as->reg('r11'); }
                    my $di  = $as->reg($d); my $rex = 0x48;
                    $rex |= 0x04 if $si >= 8; $rex |= 0x01 if $di >= 8;
                    $as->append_code( pack( 'CCCC', $rex, 0x09, 0xC0 | ( ( $si & 7 ) << 3 ) | ( $di & 7 ) ) );
                }
                elsif ( $op =~ /^(add|sub|mul)$/ ) {
                    my $d  = $reg_map{ $inst->{dest} }; my $lv = $val->( $inst->{args}[0] ); my $rv = $val->( $inst->{args}[1] );
                    $as->mov_reg( $d, $lv ) if $d ne $lv;
                    if ( $inst->{args}[1] =~ /^%/ ) {
                        if    ( $op eq 'add' ) { $as->add_reg( $d, $rv ); }
                        elsif ( $op eq 'sub' ) { $as->sub_reg( $d, $rv ); }
                        else                   { $as->mul_reg( $d, $rv ); }
                    }
                    else {
                        if    ( $op eq 'add' ) { $as->add_imm( $d, $rv ); }
                        elsif ( $op eq 'sub' ) { $as->sub_imm( $d, $rv ); }
                        else                   { $as->mov_imm( 'r11', $rv ); $as->mul_reg( $d, 'r11' ); }
                    }
                }
                elsif ( $op =~ /^(div|mod)$/ ) {
                    my $d  = $reg_map{ $inst->{dest} }; my $lv = $val->( $inst->{args}[0] ); my $rv = $val->( $inst->{args}[1] );
                    $as->mov_reg( 'rax', $lv ); $as->append_code( pack( 'CC', 0x48, 0x99 ) );
                    if   ( $inst->{args}[1] =~ /^%/ ) { $as->idiv_reg($rv); }
                    else                              { $as->mov_imm( 'r11', $rv ); $as->idiv_reg('r11'); }
                    $as->mov_reg( $d, ( $op eq 'div' ? 'rax' : 'rdx' ) );
                }
                elsif ( $op =~ /^cmp_(eq|ne|lt|gt)$/ ) {
                    my $type = $1; my $d    = $reg_map{ $inst->{dest} }; my $lv   = $val->( $inst->{args}[0] ); my $rv   = $val->( $inst->{args}[1] );
                    if ( $inst->{args}[1] =~ /^%/ ) { $as->cmp_reg_reg( $lv, $rv ); }
                    else                            { $as->cmp_reg_imm( $lv, $rv ); }
                    $as->mov_imm( $d, 0 );
                    my $cc_map = { eq => 0x94, ne => 0x95, lt => 0x9C, gt => 0x9F };
                    $as->setcc( $cc_map->{$type}, $d );
                }
                elsif ( $op eq 'push' ) {
                    my $v = $val->( $inst->{args}[0] );
                    if   ( $inst->{args}[0] =~ /^%/ ) { $as->push_reg($v); }
                    else                              { $as->push_imm($v); }
                }
                elsif ( $op eq 'pop' ) { $as->pop_reg( $reg_map{ $inst->{dest} } ); }
                elsif ( $op eq 'builtin_print_char' ) {
                    my $char    = $val->( $inst->{args}[0] );
                    my $src_reg = ( $inst->{args}[0] =~ /^%/ ) ? $char : 'r11';
                    $as->mov_imm( 'r11', $char ) if $inst->{args}[0] !~ /^%/;
                    $as->store_mem_disp_byte( 'rsp', 64, $src_reg );
                    if ( $driver->os eq 'win64' ) {
                        $as->mov_imm( 'rcx', -11 );
                        $as->call_rva( $driver->import_rva('GetStdHandle'), $driver->text_rva );
                        $as->mov_reg( 'rcx', 'rax' );
                        $as->lea_reg_disp( 'rdx', 'rsp', 64 );
                        $as->mov_imm( 'r8', 1 );
                        $as->lea_reg_disp( 'r9', 'rsp', 88 );
                        $as->mov_imm( 'r10', 0 );
                        $as->store_mem_disp_reg( 'rsp', 32, 'r10' );
                        $as->call_rva( $driver->import_rva('WriteFile'), $driver->text_rva );
                    }
                    else {
                        $as->mov_imm( 'rax', ( $driver->os eq 'macos' ? 0x2000004 : 1 ) );
                        $as->mov_imm( 'rdi', 1 );
                        $as->lea_reg_disp( 'rsi', 'rsp', 64 );
                        $as->mov_imm( 'rdx', 1 );
                        $as->syscall();
                    }
                }
                elsif ( $op eq 'builtin_print' ) {
                    my $p = $reg_map{ $inst->{args}[0] };
                    if ( $driver->os eq 'win64' ) {
                        $as->mov_imm( 'rcx', -11 );
                        $as->call_rva( $driver->import_rva('GetStdHandle'), $driver->text_rva );
                        $as->mov_reg( 'rcx', 'rax' );
                        $as->mov_reg( 'rdx', $p );
                        $as->add_imm( 'rdx', 24 );
                        $as->load_reg_mem( 'r8', $p );
                        $as->lea_reg_disp( 'r9', 'rsp', 88 );
                        $as->mov_imm( 'rax', 0 );
                        $as->store_mem_disp_reg( 'rsp', 32, 'rax' );
                        $as->call_rva( $driver->import_rva('WriteFile'), $driver->text_rva );
                    }
                    else {
                         $as->mov_reg( 'r11', $p );
                        $as->mov_imm( 'rax', 1 );
                        $as->mov_imm( 'rdi', 1 );
                        $as->load_reg_mem( 'rdx', 'r11' );
                        $as->mov_reg( 'rsi', 'r11' );
                        $as->add_imm( 'rsi', 24 );
                        $as->syscall();
                    }
                }
                elsif ( $op eq 'exit_program' ) {
                    my $code_val = $val->( $inst->{args}[0] );
                    my $dest     = ( $arch eq 'x64' ? 'rdi' : 'x0' );
                    if ( $inst->{args}[0] =~ /^%/ ) { $as->mov_reg( $dest, $code_val ) if $dest ne $code_val; }
                    else                            { $as->mov_imm( $dest, $code_val // 0 ); }
                    if ( $driver->os eq 'win64' ) {
                        $as->mov_reg( 'rcx', $dest );
                        $as->call_rva( $driver->import_rva('ExitProcess'), $driver->text_rva );
                    }
                    else {
                        $driver->exit_reg($dest);
                        $as->append_code(pack('CC', 0x0F, 0x0B));
                    }
                }
                elsif ( $op eq 'map_op' ) {
                    my $d = $reg_map{ $inst->{dest} }; my $s = $val->( $inst->{args}[0] ); $as->mov_reg( $d, $s ) if $d ne $s;
                }
                elsif ( $op eq 'shadow_push' ) {
                    my $v   = $val->( $inst->{args}[0] );
                    my $iso = ( $arch eq 'x64' ? 'r14' : 'x27' );
                    $as->push_reg('r10');
                    $as->load_reg_mem( 'r11', $iso,  $driver->iso_offset('current_fcb') );
                    $as->load_reg_mem( 'r10', 'r11', $driver->fcb_offset('shadow_ptr') );
                    if ( $inst->{args}[0] =~ /^%/ ) { $as->store_mem_disp_reg( 'r10', 0, $v ); }
                    else                            { $as->mov_imm( 'r9', $v ); $as->store_mem_disp_reg( 'r10', 0, 'r9' ); }
                    $as->add_imm( 'r10', 8 );
                    $as->store_mem_disp_reg( 'r11', $driver->fcb_offset('shadow_ptr'), 'r10' );
                    $as->pop_reg('r10');
                }
                elsif ( $op eq 'fiber_transfer' ) {
                    my $target = $val->( $inst->{args}[0] ); my $v      = $val->( $inst->{args}[1] ); my $dest   = $reg_map{ $inst->{dest} };
                    my $iso    = ( $arch eq 'x64' ? 'r14' : 'x27' );
                    if ( $inst->{args}[1] =~ /^%/ ) { $as->mov_reg( 'rax', $v ) if $v ne 'rax'; } else { $as->mov_imm( 'rax', $v ); }
                    for my $r (qw(rbp rsi rdi rbx r12 r13 r14 r15)) { $as->push_reg($r); }
                    $as->load_reg_mem( 'r11', $iso, $driver->iso_offset('current_fcb') );
                    $as->store_mem_disp_reg( 'r11',   $driver->fcb_offset('sp'),          'rsp' );
                    $as->store_mem_disp_reg( $target, $driver->fcb_offset('caller'),      'r11' );
                    $as->store_mem_disp_reg( $iso,    $driver->iso_offset('current_fcb'), $target );
                    $as->load_reg_mem( 'rsp', $target, $driver->fcb_offset('sp') );
                    for my $r ( reverse qw(rbp rsi rdi rbx r12 r13 r14 r15) ) { $as->pop_reg($r); }
                    if ( defined($dest) ) { $as->mov_reg( $dest, 'rax' ) if $dest ne 'rax'; }
                }
                elsif ( $op eq 'sys_alloc' ) {
                    my $d  = $reg_map{ $inst->{dest} }; my $sz = $val->( $inst->{args}[0] );
                    if ( $driver->os eq 'win64' ) {
                        $as->mov_imm( 'rcx', 0 );
                        if ( $inst->{args}[0] =~ /^%/ ) { $as->mov_reg( 'rdx', $sz ); } else { $as->mov_imm( 'rdx', $sz ); }
                        $as->mov_imm( 'r8', 0x3000 ); $as->mov_imm( 'r9', 0x04 );
                        $as->call_rva( $driver->import_rva('VirtualAlloc'), $driver->text_rva );
                        $as->mov_reg( $d, 'rax' );
                    }
                    else {
                        $as->mov_imm( 'rax', 9 ); $as->mov_imm( 'rdi', 0 );
                        if ( $inst->{args}[0] =~ /^%/ ) { $as->mov_reg( 'rsi', $sz ); } else { $as->mov_imm( 'rsi', $sz ); }
                        $as->mov_imm( 'rdx', 3 ); $as->mov_imm( 'r10', 0x22 ); $as->mov_imm( 'r8',  -1 ); $as->mov_imm( 'r9',  0 );
                        $as->syscall();
                        $as->mov_reg( $d, 'rax' );
                    }
                }
                elsif ( $op eq 'setup_page_fault_handler' ) {
                    if ( $driver->os eq 'win64' ) {
                        $as->mov_imm( 'rcx', 1 );
                        $as->lea_rva( 'rdx', 'M_veh_handler', $driver->text_rva );
                        $as->call_rva( $driver->import_rva('AddVectoredExceptionHandler'), $driver->text_rva );
                    }
                    else {
                        $as->lea_rva( 'r11', 'M_segv_handler', $driver->text_rva );
                        $as->store_mem_disp_reg( 'rsp', 32, 'r11' );
                        $as->mov_imm( 'r11', 4 ); $as->store_mem_disp_reg( 'rsp', 40, 'r11' );
                        $as->mov_imm( 'r11', 0 ); $as->store_mem_disp_reg( 'rsp', 48, 'r11' );
                        $as->mov_imm( 'rax', 13 ); $as->mov_imm( 'rdi', 11 );
                        $as->lea_reg_disp( 'rsi', 'rsp', 32 );
                        $as->mov_imm( 'rdx', 0 ); $as->mov_imm( 'r10', 8 );
                        $as->syscall();
                    }
                }
                elsif ( $op eq 'setup_console' ) {
                    if ( $driver->os eq 'win64' ) {
                        $as->mov_imm( 'rcx', 65001 );
                        $as->call_rva( $driver->import_rva('SetConsoleOutputCP'), $driver->text_rva );
                    }
                }
                elsif ( $op eq 'emit_native_handlers' ) {
                    if ( $driver->os eq 'win64' ) {
                        $as->mark_label('M_veh_handler');
                        $as->load_reg_mem( 'rax', 'rcx', 0 ); $as->append_code( pack( 'CCC', 0x44, 0x8B, 0x18 ) );
                        $as->cmp_reg_imm_32( 'r11', 0xC0000005 ); $as->jcc( 5, 'veh_not_handled' );
                        $as->load_reg_mem( 'r8', 'rax', 40 ); $as->mov_imm( 'r11', -4096 ); $as->append_code( pack( 'CCC', 0x4D, 0x21, 0xD8 ) );
                        $as->sub_imm( 'rsp', 40 );
                        $as->mov_reg( 'rcx', 'r8' ); $as->mov_imm( 'rdx', 4096 ); $as->mov_imm( 'r8',  0x1000 ); $as->mov_imm( 'r9',  4 );
                        $as->call_rva( $driver->import_rva('VirtualAlloc'), $driver->text_rva );
                        $as->add_imm( 'rsp', 40 ); $as->cmp_reg_imm( 'rax', 0 ); $as->jcc( 4, 'veh_not_handled' );
                        $as->mov_imm( 'rax', -1 ); $as->append_code( pack( 'C', 0xC3 ) );
                        $as->mark_label('veh_not_handled');
                        $as->mov_imm( 'rax', 0 ); $as->append_code( pack( 'C', 0xC3 ) );
                    }
                    else {
                        $as->mark_label('M_segv_handler');
                        $as->load_reg_mem( 'rdi', 'rsi', 16 ); $as->mov_imm( 'r11', -4096 ); $as->append_code( pack( 'CCC', 0x48, 0x21, 0xDF ) );
                        $as->mov_imm( 'rsi', 4096 ); $as->mov_imm( 'rdx', 3 ); $as->mov_imm( 'rax', 10 ); $as->syscall();
                        $as->mov_imm( 'rax', 15 ); $as->syscall();
                    }
                }
                elsif ( $op eq 'load_mem_byte' ) {
                    my $d    = $reg_map{ $inst->{dest} }; my $base = $reg_map{ $inst->{args}[0] }; my $idx  = $inst->{args}[1];
                    if ( $idx =~ /^%/ ) {
                        $as->mov_reg( 'r11', $base ); $as->add_reg( 'r11', $reg_map{$idx} );
                        $as->load_reg_mem_byte( $d, 'r11', 0 );
                    }
                    else { $as->load_reg_mem_byte( $d, $base, $idx ); }
                }
                elsif ( $op eq 'store_mem_byte' ) {
                    my $base    = $reg_map{ $inst->{args}[0] }; my $idx     = $inst->{args}[1];
                    my $src     = $val->( $inst->{args}[2] ); my $src_reg = ( $inst->{args}[2] =~ /^%/ ) ? $src : 'r11';
                    $as->mov_imm( 'r11', $src ) if $inst->{args}[2] !~ /^%/;
                    if ( $idx =~ /^%/ ) {
                        $as->push_reg('rax'); $as->mov_reg( 'rax', $base ); $as->add_reg( 'rax', $reg_map{$idx} );
                        $as->store_mem_disp_byte( 'rax', 0, $src_reg ); $as->pop_reg('rax');
                    }
                    else { $as->store_mem_disp_byte( $base, $idx, $src_reg ); }
                }
                elsif ( $op eq 'load_mem_disp' ) { $as->load_reg_mem( $reg_map{ $inst->{dest} }, $reg_map{ $inst->{args}[0] }, $inst->{args}[1] ); }
                elsif ( $op eq 'store_mem_disp' ) { $as->store_mem_disp_reg( $reg_map{ $inst->{args}[0] }, $inst->{args}[1], $val->( $inst->{args}[2] ) ); }
                elsif ( $op eq 'load_iso_disp' ) { $as->load_reg_mem( $reg_map{ $inst->{dest} }, ( $arch eq 'x64' ? 'r14' : 'x27' ), $inst->{args}[0] ); }
                elsif ( $op eq 'store_iso_disp' ) { $as->store_mem_disp_reg( ( $arch eq 'x64' ? 'r14' : 'x27' ), $inst->{args}[0], $val->( $inst->{args}[1] ) ); }
                elsif ( $op eq 'get_arg' ) { $as->mov_reg( $reg_map{ $inst->{dest} }, $self->_abi_arg_reg( $inst->{args}[0], $driver->os ) ); }
                elsif ( $op eq 'set_isolate_ctx' ) { $as->mov_reg( ( $arch eq 'x64' ? 'r14' : 'x27' ), $reg_map{ $inst->{args}[0] } ); }
                elsif ( $op eq 'get_isolate_ctx' ) { $as->mov_reg( $reg_map{ $inst->{dest} },          ( $arch eq 'x64' ? 'r14' : 'x27' ) ); }
                elsif ( $op eq 'enter_func' ) {
                    $as->append_code( pack( 'C*', 0x55, 0x56, 0x57, 0x53, 0x41, 0x54, 0x41, 0x55, 0x41, 0x56, 0x41, 0x57, 0x48, 0x89, 0xE5 ) );
                    $as->sub_imm( 'rsp', $driver->frame_local_size ) if $arch eq 'x64';
                }
                elsif ( $op eq 'leave_func' ) {
                    my $rv = $val->( $inst->{args}[0] );
                    if ( defined $rv ) {
                        if ( $inst->{args}[0] =~ /^%/ ) { $as->mov_reg( 'rax', $rv ) if $rv ne 'rax'; }
                        else                            { $as->mov_imm( 'rax', $rv ); }
                    }
                    $as->add_imm( 'rsp', $driver->frame_local_size ) if $arch eq 'x64';
                    $as->append_code( pack( 'C*', 0x41, 0x5F, 0x41, 0x5E, 0x41, 0x5D, 0x41, 0x5C, 0x5B, 0x5F, 0x5E, 0x5D, 0xC3 ) );
                }
                elsif ( $op eq 'call_func' ) {
                    my $target = $inst->{args}[0]; my $dest   = $reg_map{ $inst->{dest} } if defined $inst->{dest};
                    my @args   = @{ $inst->{args} }[ 1 .. $#{ $inst->{args} } ];
                    for my $i ( 0 .. $#args ) {
                        my $arg     = $args[$i]; my $dst_abi = $self->_abi_arg_reg( $i, $driver->os );
                        if    ( $arg =~ /^%/ )       { $as->mov_reg( $dst_abi, $reg_map{$arg} ); }
                        elsif ( $arg =~ /^[A-Z_]/i ) { $as->lea_rva( $dst_abi, $arg, $driver->text_rva ); }
                        else                         { $as->mov_imm( $dst_abi, $arg ); }
                    }
                    $as->call_label($target);
                    if ( defined $dest ) { $as->mov_reg( $dest, 'rax' ); }
                }
            }
        }
        method _analyze_liveness($insts) {
            my %live;
            for ( my $i = 0; $i < @$insts; $i++ ) {
                my $ins = $insts->[$i];
                if ( defined $ins->{dest} ) { $live{ $ins->{dest} }{start} //= $i; $live{ $ins->{dest} }{end} = $i; }
                if ( $ins->{op} eq 'cond_br' && defined $ins->{reg} ) { $live{ $ins->{reg} }{end} = $i; }
                if ( defined $ins->{args} ) { for my $arg ( @{ $ins->{args} } ) { if ( defined $arg && !ref($arg) && $arg =~ /^%/ ) { $live{$arg}{start} //= $i; $live{$arg}{end} = $i; } } }
            }
            my %label_pos;
            for ( my $i = 0; $i < @$insts; $i++ ) { if ( $insts->[$i]{op} eq 'label' ) { $label_pos{ $insts->[$i]{name} } = $i; } }
            for ( my $i = 0; $i < @$insts; $i++ ) {
                my $ins    = $insts->[$i]; my $target = $ins->{target} // $ins->{true_l} // $ins->{false_l};
                if ( defined $target && exists $label_pos{$target} ) {
                    my $tpos = $label_pos{$target};
                    if ( $tpos < $i ) { for my $r ( keys %live ) { if ( $live{$r}{start} <= $tpos && $live{$r}{end} >= $tpos ) { $live{$r}{end} = $i if $i > $live{$r}{end}; } } }
                }
            }
            return %live;
        }

        method _allocate_registers( $live_ref, $driver ) {
            my %live = %$live_ref; my %rmap; my @free;
            if ( $arch eq 'arm64' ) { @free = qw(x19 x20 x21 x22 x23 x24 x25 x26 x28); }
            else {
                if ( $driver->os eq 'win64' ) { @free = qw(rbx rsi rdi r12 r13 r15 r8 r9 r10); }
                else { @free = qw(rbx r12 r13 r15 r8 r9 r10); }
            }
            my @intervals = sort { ( $a->{start} // 0 ) <=> ( $b->{start} // 0 ) } map { { vreg => $_, %{ $live{$_} } } } keys %live;
            my @active;
            for my $iv (@intervals) {
                @active = grep { if ( $_->{end} < ( $iv->{start} // 0 ) ) { push @free, $_->{phys}; 0; } else { 1; } } @active;
                my $phys = shift @free;
                if (!defined $phys) { $phys = $active[0]->{phys}; }
                $rmap{ $iv->{vreg} } = $phys;
                push @active, { vreg => $iv->{vreg}, phys => $phys, end => $iv->{end} };
                @active = sort { $a->{end} <=> $b->{end} } @active;
            }
            return %rmap;
        }
    }
}
1;
