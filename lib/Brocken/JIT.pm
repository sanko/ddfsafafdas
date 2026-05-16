package Brocken::JIT {
    use v5.40;
    use feature 'class';
    no warnings 'experimental::class', 'uninitialized';
    use Brocken;
    use Brocken::Runtime::Memory; # <--- CRITICAL FIX

    class Brocken::JIT {
        field $driver : param = undef;
        field $arch   : param = undef;
        field $os     : param = undef;
        field $standalone : param : reader = 0;
        field $xsub_idx = 0;

        ADJUST {
            $driver //= Brocken::Compiler->new();
            $arch   //= $driver->arch;
            $os     //= $driver->os;
        }

        method compile_and_run($source) {
            my $result = $self->compile_source($source);
            return $self->_invoke($result->{addr});
        }

        method compile_source($source) {
            my $tokens = Brocken::Lexer->new( source => $source )->lex();
            my $ast    = Brocken::Parser->new( tokens => $tokens )->parse();

            my $ds = Brocken::Compiler::DataSegment->new();
            my $lowering = Brocken::Compiler::Lowering->new( data_segment => $ds, driver => $driver );
            $lowering->set_skip_runtime($self->standalone);
            $lowering->lower_program($ast);

            require Brocken::Compiler::Optimizer;
            Brocken::Compiler::Optimizer->new()->optimize( $lowering->builder );

            my @insts  = $lowering->builder->instructions;
            my %rmap   = $self->_simple_allocate( \@insts );
            my $jit_as = $self->_create_assembler();

            # 1. Allocate and Copy Data Segment
            my $ds_raw = $ds->get_raw_data();
            my $ds_mem = Brocken::Runtime::Memory::allocate_executable(length($ds_raw) || 16);
            Brocken::Runtime::Memory::copy_to_ptr($ds_mem->{addr}, $ds_raw);
            my $ds_addr = $ds_mem->{addr};

            # 2. Emit Code
            for my $inst (@insts) {
                $self->_emit_inst($jit_as, $inst, \%rmap, $ds_addr);
            }

            # 3. Resolve and Copy Code Segment
            my $raw = $jit_as->code;
            my $code_mem = Brocken::Runtime::Memory::allocate_executable(length($raw));
            $jit_as->resolve($code_mem->{addr});

            # Copy resolved code
            Brocken::Runtime::Memory::copy_to_ptr($code_mem->{addr}, $jit_as->code);

            return { addr => $code_mem->{addr} };
        }

        method _emit_inst($as, $inst, $rmap, $ds_addr) {
            my $op = $inst->{op};
            my $d  = $rmap->{$inst->{dest}};

            my $v = sub {
                my $arg = shift;
                return $rmap->{$arg} if defined $arg && exists $rmap->{$arg};
                return $arg if defined $arg && $arg =~ /^-?\d+$/;
                return 0;
            };

            if    ($op eq 'label')      { $as->mark_label($inst->{name} // $inst->{target}); }
            elsif ($op eq 'jmp')        { $as->jmp($inst->{target}); }
            elsif ($op eq 'cond_br')    {
                my $reg = $v->($inst->{reg});
                $as->test_reg_reg($reg, $reg);
                $as->jcc('nz', $inst->{true_l});
                $as->jmp($inst->{false_l});
            }
            elsif ($op eq 'constant')   {
                my $val = $inst->{args}[0] // 0;
                if ($inst->{type} =~ /Float|double/) { $val = unpack('Q', pack('d', $val)); }
                $as->mov_imm($d, $val);
            }
            elsif ($op eq 'mov')        {
                my $src = $v->($inst->{args}[0]);
                ($src =~ /^[a-z]/i) ? $as->mov_reg($d, $src) : $as->mov_imm($d, $src);
            }
            elsif ($op =~ /^(add|sub|mul|and|or|xor)$/) {
                my $l = $v->($inst->{args}[0]);
                my $r = $v->($inst->{args}[1]);
                $as->mov_reg($d, $l) if $d ne $l;
                ($r =~ /^[a-z]/i) ? $as->${\($op."_reg")}($d, $r) : $as->${\($op."_imm")}($d, $r);
            }
            elsif ($op eq 'intrinsic_print') {
                my $reg = $rmap->{$inst->{args}[0]};
                $as->mov_reg('rsi', $reg);
                $as->add_imm('rsi', 16);
                $as->load_reg_mem('rdx', $reg, 0);
                ($os eq 'win64') ? $self->_win32_write_stdout($as) : $self->_linux_write($as, 1);
            }
            elsif ($op eq 'enter_func') {
                $as->push_reg('rbp'); $as->mov_reg('rbp', 'rsp'); $as->sub_imm('rsp', 1024);

                my $giso_off = $driver->global_iso_offset;
                if (defined $giso_off) {
                    $as->mov_imm('r11', $ds_addr + $giso_off);
                    $as->load_reg_mem('r14', 'r11', 0);
                }
            }
            elsif ($op =~ /ret|leave_func/) {
                if (defined $inst->{args}[0]) {
                    my $rv = $v->($inst->{args}[0]);
                    ($rv =~ /^[a-z]/i) ? $as->mov_reg('rax', $rv) : $as->mov_imm('rax', $rv);
                }
                $as->mov_reg('rsp', 'rbp'); $as->pop_reg('rbp'); $as->ret();
            }
            elsif ($op eq 'load_data_addr') {
                my $offset = $inst->{args}[0] // 0;
                $as->mov_imm($d, $ds_addr + $offset);
            }
        }

        method _simple_allocate($insts) {
            # Reserve r10, r11, and r14
            my @free = qw(rax rbx rcx rdx rsi rdi r8 r9 r12 r13 r15);
            my %map;
            for my $i (@$insts) {
                # Map dest, reg, and all args
                for my $k (qw(dest reg)) {
                    if (defined $i->{$k} && $i->{$k} =~ /^%/ && !exists $map{$i->{$k}}) {
                        $map{$i->{$k}} = shift(@free) // 'r10';
                    }
                }
                if (defined $i->{args}) {
                    for my $arg (@{$i->{args}}) {
                        if (defined $arg && !ref($arg) && $arg =~ /^%/ && !exists $map{$arg}) {
                            $map{$arg} = shift(@free) // 'r10';
                        }
                    }
                }
            }
            return %map;
        }

        method _create_assembler { require Brocken::JIT::X64; return Brocken::JIT::X64->new(); }
        method _linux_write($as, $fd) { $as->mov_imm('rax', 1); $as->mov_imm('rdi', $fd); $as->syscall(); }

        method _invoke($ptr) {
            my $sn = "Brocken::JIT::Exec_" . ++$xsub_idx;
            require DynaLoader;
            DynaLoader::dl_install_xsub($sn, $ptr, __FILE__);
            no strict 'refs';
            return $sn->();
        }

        method _win32_write_stdout($as) {
            require DynaLoader;
            my $k32 = DynaLoader::dl_load_file("kernel32.dll");
            my $gsh = DynaLoader::dl_find_symbol($k32, "GetStdHandle");
            my $wf  = DynaLoader::dl_find_symbol($k32, "WriteFile");
            $as->push_reg('rsi'); $as->push_reg('rdx');
            $as->mov_imm('rcx', -11);
            $as->mov_imm('rax', $gsh);
            $as->sub_imm('rsp', 32); $as->call_reg('rax'); $as->add_imm('rsp', 32);
            $as->mov_reg('rcx', 'rax');
            $as->pop_reg('r8'); $as->pop_reg('rdx');
            $as->sub_imm('rsp', 48);
            $as->lea_reg_disp('r9', 'rsp', 40);
            $as->mov_imm('rax', 0); $as->store_mem_disp_reg('rsp', 32, 'rax');
            $as->mov_imm('rax', $wf); $as->call_reg('rax');
            $as->add_imm('rsp', 48);
        }
    }
}
1;
