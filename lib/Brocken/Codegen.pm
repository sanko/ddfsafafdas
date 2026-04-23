package Brocken::Codegen {
    use v5.40;
    use utf8;
    use feature 'class';
    no warnings 'portable', 'experimental::class';

    class Brocken::Codegen {
        field $arch : param;

        method _abi_arg_reg( $idx, $os ) {
            if ( $arch eq 'arm64' ) { return "x$idx"; }
            else {
                if   ( $os eq 'win64' ) { return (qw(rcx rdx r8 r9))[$idx]; }
                else                    { return (qw(rdi rsi rdx rcx r8 r9))[$idx]; }
            }
        }

        method compile( $instructions, $pulse ) {
            my $as       = $pulse->as;
            my %liveness = $self->_analyze_liveness($instructions);
            my %reg_map  = $self->_allocate_registers( \%liveness, $pulse );
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
                    $as->jcc( $pulse->cc('nz'), $inst->{true_l} );
                    $as->jmp( $inst->{false_l} );
                }
                elsif ( $op eq 'constant' ) {
                    $as->mov_imm( $reg_map{ $inst->{dest} }, $inst->{args}[0] );
                }
                elsif ( $op eq 'load_data_addr' ) {
                    $as->lea_rva( $reg_map{ $inst->{dest} }, 0x2000 + $inst->{args}[0], 0x1000 );
                }
                elsif ( $op eq 'mov' ) {
                    my $d = $reg_map{ $inst->{dest} };
                    my $s = $inst->{args}[0];
                    if ( $s =~ /^%/ ) { $as->mov_reg( $d, $reg_map{$s} ) if $d ne $reg_map{$s}; }
                    else              { $as->mov_imm( $d, $s ); }
                }
                elsif ( $op =~ /^(add|sub|mul)$/ ) {
                    my $d  = $reg_map{ $inst->{dest} };
                    my $lv = $val->( $inst->{args}[0] );
                    my $rv = $val->( $inst->{args}[1] );
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
                    my $d  = $reg_map{ $inst->{dest} };
                    my $lv = $val->( $inst->{args}[0] );
                    my $rv = $val->( $inst->{args}[1] );
                    $as->mov_reg( 'rax', $lv );
                    $as->append_code( pack( 'CC', 0x48, 0x99 ) );    # CQO: Prepare RDX:RAX
                    if ( $inst->{args}[1] =~ /^%/ ) {

                        # If the divisor is in a register, use it
                        $as->idiv_reg($rv);
                    }
                    else {
                        # Use r11 as scratch (safe now because r11 is not in the allocator pool)
                        $as->mov_imm( 'r11', $rv );
                        $as->idiv_reg('r11');
                    }
                    $as->mov_reg( $d, ( $op eq 'div' ? 'rax' : 'rdx' ) );
                }
                elsif ( $op =~ /^cmp_(eq|ne|lt|gt)$/ ) {
                    my $type = $1;
                    my $d    = $reg_map{ $inst->{dest} };
                    my $lv   = $val->( $inst->{args}[0] );
                    my $rv   = $val->( $inst->{args}[1] );
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
                elsif ( $op eq 'pop' ) {
                    $as->pop_reg( $reg_map{ $inst->{dest} } );
                }
                elsif ( $op eq 'builtin_print_char' ) {
                    my $char    = $val->( $inst->{args}[0] );
                    my $src_reg = ( $inst->{args}[0] =~ /^%/ ) ? $char : 'r11';
                    $as->mov_imm( 'r11', $char ) if $inst->{args}[0] !~ /^%/;
                    $as->store_mem_disp_byte( 'rsp', 64, $src_reg );
                    if ( $pulse->os eq 'win64' ) {
                        $as->sub_imm( 'rsp', 48 );
                        $as->mov_imm( 'rcx', -11 );
                        $as->call_rva( 0x3008, 0x1000 );
                        $as->mov_reg( 'rcx', 'rax' );
                        $as->lea_reg_disp( 'rdx', 'rsp', 112 );
                        $as->mov_imm( 'r8', 1 );
                        $as->lea_reg_disp( 'r9', 'rsp', 88 );
                        $as->mov_imm( 'rax', 0 );
                        $as->store_mem_disp_reg( 'rsp', 32, 'rax' );
                        $as->call_rva( 0x3010, 0x1000 );
                        $as->add_imm( 'rsp', 48 );
                    }
                    else {
                        $as->mov_imm( 'rax', ( $pulse->os eq 'macos' ? 0x2000004 : 1 ) );
                        $as->mov_imm( 'rdi', 1 );
                        $as->lea_reg_disp( 'rsi', 'rsp', 64 );
                        $as->mov_imm( 'rdx', 1 );
                        $as->syscall();
                    }
                }
                elsif ( $op eq 'builtin_print' ) {
                    my $p = $reg_map{ $inst->{args}[0] };
                    if ( $pulse->os eq 'win64' ) {
                        $as->sub_imm( 'rsp', 48 );
                        $as->mov_imm( 'rcx', -11 );
                        $as->call_rva( 0x3008, 0x1000 );
                        $as->mov_reg( 'rcx', 'rax' );
                        $as->mov_reg( 'rdx', $p );
                        $as->add_imm( 'rdx', 24 );
                        $as->load_reg_mem( 'r8', $p );
                        $as->lea_reg_disp( 'r9', 'rsp', 88 );    # 40 + 48
                        $as->mov_imm( 'rax', 0 );
                        $as->store_mem_disp_reg( 'rsp', 32, 'rax' );
                        $as->call_rva( 0x3010, 0x1000 );
                        $as->add_imm( 'rsp', 48 );               # matched sub
                    }
                    else {
                        # Linux: Be careful not to use rsi/rdi for the load
                        $as->mov_reg( 'r11', $p );
                        $as->mov_imm( 'rax', 1 );                # sys_write
                        $as->mov_imm( 'rdi', 1 );                # stdout
                        $as->load_reg_mem( 'rdx', 'r11' );       # length from [r11]
                        $as->mov_reg( 'rsi', 'r11' );            # data start...
                        $as->add_imm( 'rsi', 24 );               # ...at r11 + 24
                        $as->syscall();
                    }
                }
                elsif ( $op eq 'setup_console' ) {
                    if ( $pulse->os eq 'win64' ) {
                        if ( $arch eq 'arm64' ) {
                            $as->mov_imm( 'x0', 65001 );
                            $as->call_rva( 0x3020, 0x1000 );
                        }
                        else {
                            $as->sub_imm( 'rsp', 48 );
                            $as->mov_imm( 'rcx', 65001 );
                            $as->call_rva( 0x3020, 0x1000 );
                            $as->add_imm( 'rsp', 48 );
                        }
                    }
                }
                elsif ( $op eq 'exit_program' ) {
                    my $code_val = $val->( $inst->{args}[0] );
                    my $is_reg   = ( $inst->{args}[0] =~ /^%/ );
                    if ( $arch eq 'x64' ) {
                        if ( $pulse->os eq 'win64' ) {
                            $as->sub_imm( 'rsp', 48 );
                            if ($is_reg) { $as->mov_reg( 'rcx', $code_val ) if $code_val ne 'rcx'; }
                            else         { $as->mov_imm( 'rcx', $code_val // 0 ); }
                            $as->call_rva( 0x3000, 0x1000 );
                            $as->add_imm( 'rsp', 48 );
                        }
                        else {
                            if ($is_reg) { $as->mov_reg( 'rdi', $code_val ) if $code_val ne 'rdi'; }
                            else         { $as->mov_imm( 'rdi', $code_val // 0 ); }
                            $pulse->exit_reg('rdi');
                        }
                    }
                    elsif ( $arch eq 'arm64' ) {
                        if ( $pulse->os eq 'win64' ) {
                            if ($is_reg) { $as->mov_reg( 'x0', $code_val ) if $code_val ne 'x0'; }
                            else         { $as->mov_imm( 'x0', $code_val // 0 ); }
                            $as->call_rva( 0x3000, 0x1000 );
                        }
                        else {
                            if ($is_reg) { $as->mov_reg( 'x0', $code_val ) if $code_val ne 'x0'; }
                            else         { $as->mov_imm( 'x0', $code_val // 0 ); }
                            $pulse->exit_reg('x0');
                        }
                    }
                }
                elsif ( $op eq 'map_op' ) {
                    my $d = $reg_map{ $inst->{dest} };
                    my $s = $val->( $inst->{args}[0] );
                    $as->mov_reg( $d, $s ) if $d ne $s;
                }
                elsif ( $op eq 'shadow_push' ) { }
                elsif ( $op eq 'sys_alloc' ) {
                    my $d  = $reg_map{ $inst->{dest} };
                    my $sz = $val->( $inst->{args}[0] );
                    if ( $pulse->os eq 'win64' ) {
                        $as->sub_imm( 'rsp', 48 );
                        $as->mov_imm( 'rcx', 0 );
                        if ( $inst->{args}[0] =~ /^%/ ) { $as->mov_reg( 'rdx', $sz ); }
                        else                            { $as->mov_imm( 'rdx', $sz ); }
                        $as->mov_imm( 'r8', 0x3000 );
                        $as->mov_imm( 'r9', 0x04 );
                        $as->call_rva( 0x3018, 0x1000 );
                        $as->mov_reg( $d, 'rax' );
                        $as->add_imm( 'rsp', 48 );
                    }
                    else {
                        $as->mov_imm( 'rax', 9 );    # sys_mmap

                        # FIX: Load size into rsi FIRST. If $sz was in rdi,
                        # moving 0 into rdi first would destroy the size.
                        if ( $inst->{args}[0] =~ /^%/ ) { $as->mov_reg( 'rsi', $sz ); }
                        else                            { $as->mov_imm( 'rsi', $sz ); }
                        $as->mov_imm( 'rdi', 0 );       # addr (NULL)
                        $as->mov_imm( 'rdx', 3 );       # PROT_READ | PROT_WRITE
                        $as->mov_imm( 'r10', 0x22 );    # MAP_PRIVATE | MAP_ANONYMOUS
                        $as->mov_imm( 'r8',  -1 );      # fd
                        $as->mov_imm( 'r9',  0 );       # offset
                        $as->syscall();
                        $as->mov_reg( $d, 'rax' );
                    }
                }
                elsif ( $op eq 'load_mem_byte' ) {
                    $as->load_reg_mem_byte( $reg_map{ $inst->{dest} }, $reg_map{ $inst->{args}[0] }, $inst->{args}[1] );
                }
                elsif ( $op eq 'store_mem_byte' ) {
                    my $base    = $reg_map{ $inst->{args}[0] };
                    my $disp    = $inst->{args}[1];
                    my $src     = $val->( $inst->{args}[2] );
                    my $src_reg = ( $inst->{args}[2] =~ /^%/ ) ? $src : 'r11';
                    $as->mov_imm( 'r11', $src ) if $inst->{args}[2] !~ /^%/;
                    $as->store_mem_disp_byte( $base, $disp, $src_reg );
                }
                elsif ( $op eq 'store_mem_idx_byte' ) {
                    my $base    = $reg_map{ $inst->{args}[0] };
                    my $idx     = $reg_map{ $inst->{args}[1] };
                    my $src     = $val->( $inst->{args}[2] );
                    my $src_reg = ( $inst->{args}[2] =~ /^%/ ) ? $src : 'r11';
                    $as->mov_imm( 'r11', $src ) if $inst->{args}[2] !~ /^%/;
                    $as->_emit_sib( 0x88, $src_reg, $base, $idx, 0 );
                }
                elsif ( $op eq 'load_mem_idx_byte' ) {
                    my $dest = $reg_map{ $inst->{dest} };
                    my $base = $reg_map{ $inst->{args}[0] };
                    my $idx  = $reg_map{ $inst->{args}[1] };
                    $as->_emit_sib( 0xB6, $dest, $base, $idx, 1, pack( 'C', 0x0F ) );
                }
                elsif ( $op eq 'load_mem_disp' ) {
                    $as->load_reg_mem( $reg_map{ $inst->{dest} }, $reg_map{ $inst->{args}[0] }, $inst->{args}[1] );
                }
                elsif ( $op eq 'store_mem_disp' ) {
                    $as->store_mem_disp_reg( $reg_map{ $inst->{args}[0] }, $inst->{args}[1], $val->( $inst->{args}[2] ) );
                }
                elsif ( $op eq 'get_arg' ) { $as->mov_reg( $reg_map{ $inst->{dest} }, $self->_abi_arg_reg( $inst->{args}[0], $pulse->os ) ); }
                elsif ( $op eq 'call_func' ) {
                    my $target = $inst->{args}[0];
                    my $dest   = $reg_map{ $inst->{dest} } if defined $inst->{dest};
                    my @args   = @{ $inst->{args} }[ 1 .. $#{ $inst->{args} } ];
                    for my $i ( 0 .. $#args ) {
                        my $arg     = $args[$i];
                        my $dst_abi = $self->_abi_arg_reg( $i, $pulse->os );
                        if ( $arg =~ /^%/ ) { $as->mov_reg( $dst_abi, $reg_map{$arg} ); }
                        else                { $as->mov_imm( $dst_abi, $arg ); }
                    }
                    $as->call_label($target);
                    if ( defined $dest ) { $as->mov_reg( $dest, 'rax' ); }
                }
                elsif ( $op eq 'enter_func' ) {
                    if ( $arch eq 'x64' ) {

                        # 1. push rbp; mov rbp, rsp
                        # 2. push rbx, rsi, rdi, r12, r13, r14, r15 (7 registers)
                        # Total pushed: 8 regs = 64 bytes.
                        # Call pushes return addr (8 bytes). Total offset = 72.
                        # sub rsp, 88 to reach 160 (aligned to 16).
                        $as->append_code(
                            pack(
                                'C*', 0x55, 0x48, 0x89, 0xE5,    # push rbp, mov rbp, rsp
                                0x53, 0x56, 0x57,                # push rbx, rsi, rdi
                                0x41, 0x54, 0x41, 0x55,          # push r12, r13
                                0x41, 0x56, 0x41, 0x57           # push r14, r15
                            )
                        );
                        $as->sub_imm( 'rsp', 88 );
                    }
                }
                elsif ( $op eq 'leave_func' ) {
                    my $rv = $val->( $inst->{args}[0] );
                    if ( defined $rv ) {
                        if ( $inst->{args}[0] =~ /^%/ ) { $as->mov_reg( 'rax', $rv ); }
                        else                            { $as->mov_imm( 'rax', $rv ); }
                    }
                    if ( $arch eq 'x64' ) {
                        $as->add_imm( 'rsp', 88 );

                        # Pop in reverse: r15, r14, r13, r12, rdi, rsi, rbx, rbp
                        $as->append_code(
                            pack(
                                'C*', 0x41, 0x5F, 0x41, 0x5E, 0x41, 0x5D, 0x41, 0x5C,    # r15-r12
                                0x5F, 0x5E, 0x5B, 0x5D, 0xC3                             # rdi, rsi, rbx, rbp, ret
                            )
                        );
                    }
                }
                elsif ( $op eq 'set_isolate_ctx' ) {
                    $as->mov_reg( ( $arch eq 'x64' ? 'r14' : 'x27' ), $reg_map{ $inst->{args}[0] } );
                }
                elsif ( $op eq 'load_iso_disp' ) {
                    $as->load_reg_mem( $reg_map{ $inst->{dest} }, ( $arch eq 'x64' ? 'r14' : 'x27' ), $inst->{args}[0] );
                }
                elsif ( $op eq 'store_iso_disp' ) {
                    $as->store_mem_disp_reg( ( $arch eq 'x64' ? 'r14' : 'x27' ), $inst->{args}[0], $val->( $inst->{args}[1] ) );
                }
            }
        }

        method _analyze_liveness($insts) {
            my %live;
            for ( my $i = 0; $i < @$insts; $i++ ) {
                my $ins = $insts->[$i];
                if ( defined $ins->{dest} ) { $live{ $ins->{dest} }{start} //= $i; $live{ $ins->{dest} }{end} = $i; }
                if ( $ins->{op} eq 'cond_br' && defined $ins->{reg} ) { $live{ $ins->{reg} }{end} = $i; }
                if ( defined $ins->{args} ) {
                    for my $arg ( @{ $ins->{args} } ) {
                        if ( defined $arg && !ref($arg) && $arg =~ /^%/ ) { $live{$arg}{start} //= $i; $live{$arg}{end} = $i; }
                    }
                }
            }
            my %label_pos;
            for ( my $i = 0; $i < @$insts; $i++ ) {
                if ( $insts->[$i]{op} eq 'label' ) { $label_pos{ $insts->[$i]{name} } = $i; }
            }
            for ( my $i = 0; $i < @$insts; $i++ ) {
                my $ins    = $insts->[$i];
                my $target = $ins->{target} // $ins->{true_l} // $ins->{false_l};
                if ( defined $target && exists $label_pos{$target} ) {
                    my $tpos = $label_pos{$target};
                    if ( $tpos < $i ) {    # Backward jump
                        for my $r ( keys %live ) {

                            # CHANGE: Use <= tpos to catch variables defined AT the label
                            if ( $live{$r}{start} <= $tpos && $live{$r}{end} >= $tpos ) {
                                $live{$r}{end} = $i if $i > $live{$r}{end};
                            }
                        }
                    }
                }
            }
            return %live;
        }

        method _allocate_registers( $live_ref, $pulse ) {
            my %live = %$live_ref;
            my %rmap;

            # Pool: rbx, rbp, r12, r13, r15. (Total 5 on SysV, 6 on Win64)
            # r14 is reserved for Isolate Context.
            # r10, r11 are reserved as generator scratch.
            my @free;
            if ( $arch eq 'arm64' ) {
                @free = qw(x19 x20 x21 x22 x23 x24 x25 x26 x28);
            }
            elsif ( $pulse->os eq 'win64' ) {
                @free = qw(rbx rsi rdi r12 r13 r15);
            }
            else {
                @free = qw(rbx rbp r12 r13 r15);
            }
            my @intervals = sort { ( $a->{start} // 0 ) <=> ( $b->{start} // 0 ) } map { { vreg => $_, %{ $live{$_} } } } keys %live;
            my @active;
            for my $iv (@intervals) {
                @active = grep {
                    if ( $_->{end} <= ( $iv->{start} // 0 ) ) { push @free, $_->{phys}; 0; }
                    else                                      { 1; }
                } @active;
                my $phys = shift @free;
                if ( !defined $phys ) {

                    # Debug: show which vregs are hogging registers
                    die "Out of registers! Needed for $iv->{vreg}. Active: " . join( ", ", map {"$_->{vreg} ($_->{phys})"} @active ) . "\n";
                }
                $rmap{ $iv->{vreg} } = $phys;
                push @active, { vreg => $iv->{vreg}, phys => $phys, end => $iv->{end} };
                @active = sort { $a->{end} <=> $b->{end} } @active;
            }
            return %rmap;
        }
    }
}
1;
