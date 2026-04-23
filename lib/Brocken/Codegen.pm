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
            my %reg_map  = $self->_allocate_registers( \%liveness );
            for my $inst (@$instructions) {
                my $op = $inst->{op};
                if    ( $op eq 'label' ) { $as->mark_label( $inst->{name} ); }
                elsif ( $op eq 'jmp' )   { $as->jmp( $inst->{target} ); }
                elsif ( $op eq 'cond_br' ) {
                    my $reg = $reg_map{ $inst->{reg} };
                    $as->test_reg_reg( $reg, $reg );
                    $as->jcc( $pulse->cc('nz'), $inst->{true_l} );
                    $as->jmp( $inst->{false_l} );
                }
                elsif ( $op eq 'constant' )       { $as->mov_imm( $reg_map{ $inst->{dest} }, $inst->{args}[0] ); }
                elsif ( $op eq 'load_data_addr' ) { $as->lea_rva( $reg_map{ $inst->{dest} }, 0x2000 + $inst->{args}[0], 0x1000 ); }
                elsif ( $op eq 'mov' ) {
                    my $d = $reg_map{ $inst->{dest} };
                    my $s = $reg_map{ $inst->{args}[0] };
                    $as->mov_reg( $d, $s ) if $d ne $s;
                }
                elsif ( $op =~ /^(add|sub|mul)$/ ) {
                    my $d = $reg_map{ $inst->{dest} };
                    my $l = $reg_map{ $inst->{args}[0] };
                    my $r = $reg_map{ $inst->{args}[1] };
                    $as->mov_reg( $d, $l ) if $d ne $l;
                    if    ( $op eq 'add' ) { $as->add_reg( $d, $r ); }
                    elsif ( $op eq 'sub' ) { $as->sub_reg( $d, $r ); }
                    else                   { $as->mul_reg( $d, $r ); }
                }
                elsif ( $op =~ /^cmp_(eq|ne|lt|gt)$/ ) {
                    my $type = $1;
                    my $d    = $reg_map{ $inst->{dest} };
                    my $l    = $reg_map{ $inst->{args}[0] };
                    my $r    = $reg_map{ $inst->{args}[1] };
                    $as->cmp_reg_reg( $l, $r );
                    if ( $arch eq 'x64' ) { $as->mov_imm( $d, 0 ); $as->setcc( { eq => 0x94, ne => 0x95, lt => 0x9C, gt => 0x9F }->{$type}, $d ); }
                    else                  { $as->setcc( { eq => 0x0, ne => 0x1, lt => 0xB, gt => 0xC }->{$type}, $d ); }
                }
                elsif ( $op eq 'enter_func' ) {
                    if ( $arch eq 'x64' ) {
                        $as->append_code( pack( 'C*', 0x55 ) );                                                    # push rbp
                        $as->mov_reg( 'rbp', 'rsp' );
                        $as->append_code( pack( 'C*', 0x41, 0x54, 0x41, 0x55, 0x41, 0x56, 0x41, 0x57, 0x53 ) );    # push r12-r15, rbx
                        $as->sub_imm( 'rsp', 56 ) if $pulse->os eq 'win64';    # IAT Shadow Space + Alignment + Local Slot
                    }
                    else {
                        $as->append_code( pack( 'L<', 0xA9BF53F3 ) );          # stp x19, x20, [sp, -16]!
                        $as->append_code( pack( 'L<', 0xA9BF5BF5 ) );          # stp x21, x22, [sp, -16]!
                        $as->append_code( pack( 'L<', 0xA9BF63F7 ) );          # stp x23, x24, [sp, -16]!
                        $as->append_code( pack( 'L<', 0xA9BF6BF9 ) );          # stp x25, x26, [sp, -16]!
                        $as->append_code( pack( 'L<', 0xA9BF73FB ) );          # stp x27, x28,[sp, -16]!
                        $as->append_code( pack( 'L<', 0xF81F0FFF ) );          # str x30, [sp, -16]!
                    }
                }
                elsif ( $op eq 'leave_func' ) {
                    my $ret_reg = $reg_map{ $inst->{args}[0] };
                    if ( $arch eq 'x64' ) {
                        $as->mov_reg( 'rax', $ret_reg ) if $ret_reg ne 'rax';
                        $as->add_imm( 'rsp', 56 )       if $pulse->os eq 'win64';
                        $as->append_code( pack( 'C*', 0x5B, 0x41, 0x5F, 0x41, 0x5E, 0x41, 0x5D, 0x41, 0x5C ) );    # pop rbx, r15-r12
                        $as->append_code( pack( 'C*', 0x5D ) );                                                    # pop rbp
                        $as->append_code( pack( 'C*', 0xC3 ) );                                                    # ret
                    }
                    else {
                        $as->mov_reg( 'x0', $ret_reg ) if $ret_reg ne 'x0';
                        $as->append_code( pack( 'L<', 0xF84107FF ) );                                              # ldr x30, [sp], 16
                        $as->append_code( pack( 'L<', 0xA8C173FB ) );                                              # ldp x27, x28, [sp], 16
                        $as->append_code( pack( 'L<', 0xA8C16BF9 ) );                                              # ldp x25, x26, [sp], 16
                        $as->append_code( pack( 'L<', 0xA8C163F7 ) );                                              # ldp x23, x24, [sp], 16
                        $as->append_code( pack( 'L<', 0xA8C15BF5 ) );                                              # ldp x21, x22, [sp], 16
                        $as->append_code( pack( 'L<', 0xA8C153F3 ) );                                              # ldp x19, x20, [sp], 16
                        $as->append_code( pack( 'L<', 0xD65F03C0 ) );                                              # ret
                    }
                }
                elsif ( $op eq 'get_arg' ) {
                    my $dest = $reg_map{ $inst->{dest} };
                    my $src  = $self->_abi_arg_reg( $inst->{args}[0], $pulse->os );
                    $as->mov_reg( $dest, $src ) if $dest ne $src;
                }
                elsif ( $op eq 'call_func' ) {
                    my $target = $inst->{args}[0];
                    my $dest   = $reg_map{ $inst->{dest} };
                    my @args   = @{ $inst->{args} }[ 1 .. $#{ $inst->{args} } ];
                    for my $i ( 0 .. $#args ) {
                        my $src     = $reg_map{ $args[$i] };
                        my $dst_abi = $self->_abi_arg_reg( $i, $pulse->os );
                        $as->mov_reg( $dst_abi, $src ) if $dst_abi ne $src;
                    }
                    $as->call_label($target);
                    my $ret_abi = $arch eq 'arm64' ? 'x0' : 'rax';
                    $as->mov_reg( $dest, $ret_abi ) if $dest ne $ret_abi;
                }
                elsif ( $op eq 'exit_program' ) {
                    my $ret_reg = defined $inst->{args}[0] ? $reg_map{ $inst->{args}[0] } : undef;
                    $pulse->exit_reg($ret_reg);
                }
                elsif ( $op eq 'builtin_print_int' ) {
                    my $val_reg = $reg_map{ $inst->{args}[0] };

                    # For now, let's just move the value to the exit register so we can see it in the exit code
                    # Real implementation: call a 'print_number' helper
                    $as->mov_reg( $arch eq 'arm64' ? 'x0' : 'rax', $val_reg );
                }
                elsif ( $op eq 'builtin_print' ) {
                    my $p_reg = $reg_map{ $inst->{args}[0] };
                    if ( $pulse->os eq 'win64' && $arch eq 'x64' ) {
                        $as->mov_imm( 'rcx', -11 );
                        $as->call_rva( 0x3008, 0x1000 );
                        $as->mov_reg( 'rcx', 'rax' );
                        $as->mov_reg( 'rdx', $p_reg );
                        $as->add_imm( 'rdx', 24 );
                        $as->load_reg_mem( 'r8', $p_reg );
                        $as->lea_reg_disp( 'r9', 'rsp', 40 );           # lpNumberOfBytesWritten (safe slot)
                        $as->mov_imm( 'r10', 0 );
                        $as->store_mem_disp_reg( 'rsp', 32, 'r10' );    # lpOverlapped
                        $as->call_rva( 0x3010, 0x1000 );
                    }
                    else {
                        my $sys_write = ( $pulse->os eq 'macos' ) ? 0x2000004 : ( $arch eq 'arm64' ? 64 : 1 );
                        if ( $arch eq 'x64' ) {
                            $as->mov_imm( 'rax', $sys_write );
                            $as->mov_imm( 'rdi', 1 );
                            $as->mov_reg( 'rsi', $p_reg );
                            $as->add_imm( 'rsi', 24 );
                            $as->load_reg_mem( 'rdx', $p_reg );
                            $as->syscall();
                        }
                        else {
                            $as->mov_imm( $pulse->os eq 'macos' ? 'x16' : 'x8', $sys_write );
                            $as->mov_imm( 'x0',                                 1 );
                            $as->mov_reg( 'x1', $p_reg );
                            $as->add_imm( 'x1', 24 );
                            $as->load_reg_mem( 'x2', $p_reg );
                            $as->syscall( $pulse->os eq 'macos' );
                        }
                    }
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
                        if ( defined $arg && $arg =~ /^%/ ) { $live{$arg}{start} //= $i; $live{$arg}{end} = $i; }
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
                    if ( $tpos < $i ) {
                        for my $r ( keys %live ) {
                            if ( $live{$r}{start} < $tpos && $live{$r}{end} >= $tpos ) { $live{$r}{end} = $i if $i > $live{$r}{end}; }
                        }
                    }
                }
            }
            return %live;
        }

        method _allocate_registers($live_ref) {
            my %live = %$live_ref;
            my %rmap;
            my @free      = $arch eq 'arm64' ? qw(x19 x20 x21 x22 x23 x24 x25 x26 x27 x28) : qw(r12 r13 r14 r15 rbx);
            my @intervals = sort { ( $a->{start} // 0 ) <=> ( $b->{start} // 0 ) } map { { vreg => $_, %{ $live{$_} } } } keys %live;
            my @active;
            for my $iv (@intervals) {
                @active = grep {
                    if ( $_->{end} < ( $iv->{start} // 0 ) ) { push @free, $_->{phys}; 0; }
                    else                                     { 1; }
                } @active;
                my $phys = shift @free // die "Out of registers!\n";
                $rmap{ $iv->{vreg} } = $phys;
                push @active, { vreg => $iv->{vreg}, phys => $phys, end => $iv->{end} };
                @active = sort { $a->{end} <=> $b->{end} } @active;
            }
            return %rmap;
        }
    }
};
1;
