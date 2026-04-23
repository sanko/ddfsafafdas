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

    my $val = sub {
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
            my $reg = $val->($inst->{reg});
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
            if ($s =~ /^%/) { $as->mov_reg( $d, $reg_map{$s} ) if $d ne $reg_map{$s}; }
            else            { $as->mov_imm( $d, $s ); }
        }
        elsif ( $op =~ /^(add|sub|mul)$/ ) {
            my $d = $reg_map{ $inst->{dest} };
            my $lv = $val->($inst->{args}[0]);
            my $rv = $val->($inst->{args}[1]);
            $as->mov_reg($d, $lv) if $d ne $lv;
            if ($inst->{args}[1] =~ /^%/) {
                if    ($op eq 'add') { $as->add_reg($d, $rv); }
                elsif ($op eq 'sub') { $as->sub_reg($d, $rv); }
                else                 { $as->mul_reg($d, $rv); }
            } else {
                if    ($op eq 'add') { $as->add_imm($d, $rv); }
                elsif ($op eq 'sub') { $as->sub_imm($d, $rv); }
                else                 { $as->mov_imm('r11', $rv); $as->mul_reg($d, 'r11'); }
            }
        }
  elsif ( $op =~ /^(div|mod)$/ ) {
            my $d  = $reg_map{ $inst->{dest} };
            my $lv = $val->($inst->{args}[0]);
            my $rv = $val->($inst->{args}[1]);

            $as->mov_reg('rax', $lv);
            # Manually emit CQO (Convert Quad to Oct, RDX:RAX = RAX)
            $as->append_code(pack('CC', 0x48, 0x99));

            if ($inst->{args}[1] =~ /^%/) {
                $as->idiv_reg($rv);
            } else {
                $as->mov_imm('r11', $rv);
                $as->idiv_reg('r11');
            }
            # Result in RAX, remainder in RDX
            $as->mov_reg($d, ($op eq 'div' ? 'rax' : 'rdx'));
        }
    elsif ( $op =~ /^cmp_(eq|ne|lt|gt)$/ ) {
            my $type = $1;
            my $d = $reg_map{ $inst->{dest} };
            my $lv = $val->($inst->{args}[0]);
            my $rv = $val->($inst->{args}[1]);
            if ($inst->{args}[1] =~ /^%/) { $as->cmp_reg_reg($lv, $rv); }
            else                          { $as->cmp_reg_imm($lv, $rv); }
            $as->mov_imm($d, 0);
            # Correct X64 SetCC Opcodes: 0x94 (E), 0x95 (NE), 0x9C (L), 0x9F (G)
            my $cc_map = { eq => 0x94, ne => 0x95, lt => 0x9C, gt => 0x9F };
            $as->setcc($cc_map->{$type}, $d);
        }


elsif ( $op eq 'push' ) {
            my $v = $val->($inst->{args}[0]);
            if ($inst->{args}[0] =~ /^%/) { $as->push_reg($v); }
            else                          { $as->push_imm($v); }
        }
        elsif ( $op eq 'pop' ) {
            $as->pop_reg($reg_map{$inst->{dest}});
        }


elsif ( $op eq 'builtin_print_char' ) {
            my $char = $val->($inst->{args}[0]);
            # Use 'r11' as a temp if we were passed a constant
            my $src_reg = ($inst->{args}[0] =~ /^%/) ? $char : 'r11';
            $as->mov_imm('r11', $char) if $inst->{args}[0] !~ /^%/;

            $as->store_mem_disp_byte('rsp', 64, $src_reg);

            if ($pulse->os eq 'win64') {
                $as->mov_imm('rcx', -11); $as->call_rva(0x3008, 0x1000);
                $as->mov_reg('rcx', 'rax');
                $as->lea_reg_disp('rdx', 'rsp', 64);
                $as->mov_imm('r8', 1);
                $as->lea_reg_disp('r9', 'rsp', 40);
                $as->mov_imm('r10', 0); $as->store_mem_disp_reg('rsp', 32, 'r10');
                $as->call_rva(0x3010, 0x1000);
            } else {
                $as->mov_imm('rax', ($pulse->os eq 'macos' ? 0x2000004 : 1));
                $as->mov_imm('rdi', 1);
                $as->lea_reg_disp('rsi', 'rsp', 64);
                $as->mov_imm('rdx', 1); $as->syscall();
            }
        }


        elsif ( $op eq 'exit_program' ) {
            my $code = $val->($inst->{args}[0]);
            my $dest = ($arch eq 'x64' ? 'rdi' : 'x0');
            if ($inst->{args}[0] =~ /^%/) { $as->mov_reg($dest, $code) if $dest ne $code; }
            else                          { $as->mov_imm($dest, $code); }
            $pulse->exit_reg($dest);
        }















        elsif ( $op eq 'map_op' ) {
            # MILESTONE 5 FIX: If we don't implement full map yet,
            # we must at least copy the source pointer to the destination
            # to prevent printing from a garbage register.
            my $d = $reg_map{$inst->{dest}};
            my $s = $val->($inst->{args}[0]);
            $as->mov_reg($d, $s) if $d ne $s;
        }
        elsif ( $op eq 'shadow_push' ) { } # Placeholder
        elsif ( $op eq 'load_iso_disp' ) { $as->load_reg_mem( $reg_map{$inst->{dest}}, ($arch eq 'x64' ? 'r14' : 'x27'), $inst->{args}[0] ); }
        elsif ( $op eq 'store_iso_disp' ) { $as->store_mem_disp_reg( ($arch eq 'x64' ? 'r14' : 'x27'), $inst->{args}[0], $val->($inst->{args}[1]) ); }
        elsif ( $op eq 'sys_alloc' ) {
            my $d = $reg_map{$inst->{dest}}; my $sz = $val->($inst->{args}[0]);
            if ($pulse->os eq 'win64') {
                $as->mov_imm('rcx', 0); 
                if ($inst->{args}[0] =~ /^%/) { $as->mov_reg('rdx', $sz); }
                else                          { $as->mov_imm('rdx', $sz); }
                $as->mov_imm('r8', 0x3000); $as->mov_imm('r9', 0x04);
                $as->call_rva(0x3018, 0x1000); $as->mov_reg($d, 'rax');
            } else {
                $as->mov_imm('rax', 9); $as->mov_imm('rdi', 0); 
                if ($inst->{args}[0] =~ /^%/) { $as->mov_reg('rsi', $sz); }
                else                          { $as->mov_imm('rsi', $sz); }
                $as->mov_imm('rdx', 3); $as->mov_imm('r10', 0x22);
                $as->mov_imm('r8', -1); $as->mov_imm('r9', 0); $as->syscall(); $as->mov_reg($d, 'rax');
            }
        }
        elsif ( $op eq 'load_mem_byte' )  { $as->load_reg_mem_byte( $reg_map{$inst->{dest}}, $reg_map{$inst->{args}[0]}, $inst->{args}[1] ); }
        elsif ( $op eq 'store_mem_byte' ) { $as->store_mem_disp_byte( $reg_map{$inst->{args}[0]}, $inst->{args}[1], $val->($inst->{args}[2]) ); }
        elsif ( $op eq 'load_mem_disp' )  { $as->load_reg_mem( $reg_map{$inst->{dest}}, $reg_map{$inst->{args}[0]}, $inst->{args}[1] ); }
        elsif ( $op eq 'store_mem_disp' ) { $as->store_mem_disp_reg( $reg_map{$inst->{args}[0]}, $inst->{args}[1], $val->($inst->{args}[2]) ); }
        elsif ( $op eq 'enter_func' ) {
            $as->append_code( pack( 'C*', 0x55, 0x48, 0x89, 0xE5, 0x41, 0x54, 0x41, 0x55, 0x41, 0x56, 0x41, 0x57, 0x53 ) );
            $as->sub_imm( 'rsp', 120 ) if $arch eq 'x64';
        }
        elsif ( $op eq 'leave_func' ) {
            my $rv = $val->($inst->{args}[0]);
            if (defined $rv) { $as->mov_imm('rax', $rv) if $inst->{args}[0] !~ /^%/; $as->mov_reg('rax', $rv) if $inst->{args}[0] =~ /^%/; }
            $as->add_imm( 'rsp', 120 ) if $arch eq 'x64';
            $as->append_code( pack( 'C*', 0x5B, 0x41, 0x5F, 0x41, 0x5E, 0x41, 0x5D, 0x41, 0x5C, 0x5D, 0xC3 ) );
        }
        elsif ( $op eq 'get_arg' ) { $as->mov_reg( $reg_map{$inst->{dest}}, $self->_abi_arg_reg($inst->{args}[0], $pulse->os) ); }
        elsif ( $op eq 'set_isolate_ctx' ) { $as->mov_reg( ($arch eq 'x64' ? 'r14' : 'x27'), $reg_map{$inst->{args}[0]} ); }
        elsif ( $op eq 'call_func' ) {
            my $target = $inst->{args}[0];
            my $dest   = $reg_map{ $inst->{dest} } if defined $inst->{dest};
            my @args   = @{ $inst->{args} }[ 1 .. $#{ $inst->{args} } ];
            for my $i ( 0 .. $#args ) {
                my $arg = $args[$i];
                my $dst_abi = $self->_abi_arg_reg( $i, $pulse->os );
                if ($arg =~ /^%/) { $as->mov_reg($dst_abi, $reg_map{$arg}); }
                else              { $as->mov_imm($dst_abi, $arg); }
            }
            $as->call_label($target);
            if (defined $dest) { $as->mov_reg($dest, 'rax'); }
        }
        elsif ( $op eq 'builtin_print' ) {
            my $p = $reg_map{$inst->{args}[0]};
            if ($pulse->os eq 'win64') {
                $as->mov_imm('rcx', -11); $as->call_rva(0x3008, 0x1000);
                $as->mov_reg('rcx', 'rax'); $as->mov_reg('rdx', $p); $as->add_imm('rdx', 24);
                $as->load_reg_mem('r8', $p); $as->lea_reg_disp('r9', 'rsp', 40);
                $as->mov_imm('r10', 0); $as->store_mem_disp_reg('rsp', 32, 'r10');
                $as->call_rva(0x3010, 0x1000);
            } else {
                $as->mov_imm('rax', 1); $as->mov_imm('rdi', 1); $as->mov_reg('rsi', $p);
                $as->add_imm('rsi', 24); $as->load_reg_mem('rdx', $p); $as->syscall();
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
            # x64: rbx, r12, r13, r15 are callee-saved (survive function calls).
            # r14 is reserved for Isolate Context.
    my @free = $arch eq 'arm64' ? qw(x19 x20 x21 x22 x23 x24 x25 x26 x28) : qw(rbx r12 r13 r15);
    my @intervals = sort { ( $a->{start} // 0 ) <=> ( $b->{start} // 0 ) } map { { vreg => $_, %{ $live{$_} } } } keys %live;
            my @active;
            for my $iv (@intervals) {
                @active = grep {
                    if ( $_->{end} <= ( $iv->{start} // 0 ) ) { push @free, $_->{phys}; 0; }
                    else { 1; }
                } @active;
                my $phys = shift @free // die "Out of registers! (Active: " . join(", ", map { $_->{vreg} . ":" . $_->{end} } @active) . ")\n";
                $rmap{ $iv->{vreg} } = $phys;
                push @active, { vreg => $iv->{vreg}, phys => $phys, end => $iv->{end} };
                @active = sort { $a->{end} <=> $b->{end} } @active;
            }
            return %rmap;
        }
    }
};
1;
