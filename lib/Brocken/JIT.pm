package Brocken::JIT {
    use v5.40;
    use utf8;
    use feature 'class';
    no warnings 'experimental::class', 'uninitialized';
    use Brocken;
    use Brocken::Compiler::DataSegment;
    use Brocken::Compiler::Lowering;
    use Brocken::Compiler::Optimizer;

    class Brocken::JIT {
        field $driver : param;
        field $arch : param;
        field $os : param;
        field %compiled_cache;
        field $standalone : param : reader = 0;
        field $xsub_idx = 0;

        method compile_and_run($source) {
            my $result = $self->compile_source($source);
            return $self->execute($result);
        }

        method compile_source($source) {
            my $tokens = Brocken::Lexer->new( source => $source )->lex();
            my $ast    = Brocken::Parser->new( tokens => $tokens )->parse();
            return $self->_compile_ast($ast);
        }

        method _compile_ast($ast) {
            my $skip_runtime = $self->standalone;

            my $eval_driver = $driver // _create_eval_driver($arch, $os);

            my $ds       = Brocken::Compiler::DataSegment->new();
            my $lowering = Brocken::Compiler::Lowering->new(
                data_segment => $ds,
                driver       => $eval_driver
            );

            if ($skip_runtime) {
                $lowering->set_skip_runtime(1);
            }
            else {
                $lowering->set_skip_runtime(0);
            }

            warn "JIT: Starting compilation...\n" if $ENV{BROCKEN_JIT_DEBUG};
            $lowering->lower_program($ast);
            warn "JIT: Lowering complete.\n" if $ENV{BROCKEN_JIT_DEBUG};

            my $optimizer = Brocken::Compiler::Optimizer->new();
            $optimizer->optimize( $lowering->builder );
            warn "JIT: Optimization complete.\n" if $ENV{BROCKEN_JIT_DEBUG};

            my @insts = $lowering->builder->instructions;
            my $jit_as = $self->_create_assembler();
            my %rmap = $self->_simple_allocate(\@insts);

            # Emit code
            warn "JIT: Emitting code...\n" if $ENV{BROCKEN_JIT_DEBUG};
            for my $i ( 0 .. $#insts ) {
                my $inst = $insts[$i];
                my $op   = $inst->{op};
                my $dest_reg = exists $rmap{ $inst->{dest} } ? $rmap{ $inst->{dest} } : undef;

                if ( $op eq 'label' ) {
                    $jit_as->mark_label($inst->{name} // $inst->{target});
                }
                elsif ( $op eq 'jmp' ) {
                    $jit_as->jmp($inst->{args}[0] // $inst->{target});
                }
                elsif ( $op eq 'cond_br' ) {
                    my $reg = $rmap{ $inst->{reg} } // $rmap{ $inst->{args}[0] } // 'rax';
                    $jit_as->test_reg_reg($reg, $reg);
                    $jit_as->jcc('nz', $inst->{true_l});
                    $jit_as->jmp($inst->{false_l});
                }
                elsif ( $op eq 'intrinsic_print' ) {
                    my $arg = $inst->{args}[0];
                    my $reg = exists $rmap{$arg} ? $rmap{$arg} : 'rdi';
                    $self->_jit_emit_string($jit_as, $reg);
                }
                elsif ( $op eq 'intrinsic_print_char' ) {
                    my $arg = $inst->{args}[0];
                    my $reg = exists $rmap{$arg} ? $rmap{$arg} : 'rdi';
                    $self->_jit_emit_char($jit_as, $reg);
                }
                elsif ( $op eq 'intrinsic_exit' ) {
                    my $arg = $inst->{args}[0];
                    my $code = !ref($arg) && defined($arg) && $arg =~ /^-?\d+$/ ? $arg : (exists $rmap{$arg} ? $rmap{$arg} : 0);
                    $self->_jit_emit_exit($jit_as, $code);
                }
                elsif ( $op eq 'intrinsic_alloc' ) {
                    my $arg = $inst->{args}[0];
                    my $size = exists $rmap{$arg} ? $rmap{$arg} : $arg;
                    $self->_jit_emit_alloc($jit_as, $size, $dest_reg);
                }
                elsif ( $op eq 'call_native' ) {
                    my @args = @{$inst->{args}};
                    my $lib_name = shift @args;
                    my $sym_name = shift @args;
                    my $sig      = shift @args;
                    $self->_jit_emit_call_native($jit_as, \%rmap, $inst, $lib_name, $sym_name, $sig, \@args, $ds);
                }
                elsif ( $op =~ /^intrinsic_/ ) {
                    # Skip unknown intrinsics for now, or handle them specifically
                }
                else {
                    $self->_jit_emit_op($jit_as, \%rmap, $inst, $dest_reg, $ds, $eval_driver);
                }
            }

            my $raw = $jit_as->code;
            my $executable_info = $self->_make_executable(\$raw);
            my $base_addr = $executable_info->{addr};
            $jit_as->resolve($base_addr);

            # Re-update the code in the buffer after resolution
            my $buf = $executable_info->{buf};
            my $offset = $executable_info->{offset} // 0;
            substr($$buf, $offset, length($jit_as->code)) = $jit_as->code;

            if ($ENV{BROCKEN_JIT_DEBUG}) {
                warn "JIT Code Hex Dump (" . length($jit_as->code) . " bytes):\n";
                for ( my $i = 0; $i < length($jit_as->code); $i += 16 ) {
                    my $chunk = substr( $jit_as->code, $i, 16 );
                    warn sprintf( "%04X: %-40s\n", $i, unpack( "H*", $chunk ) );
                }
            }

            return {
                code       => $executable_info->{executable},
                size       => length($jit_as->code),
                raw        => \$raw,
                class_info => { $lowering->class_info }
            };
        }

        method _create_assembler {
            if ( $arch eq 'x64' ) {
                require Brocken::JIT::X64;
                return Brocken::JIT::X64->new();
            }
            die "Unsupported arch: $arch";
        }

        method _jit_emit_string($jit_as, $reg) {
            # Brocken String: [8 bytes GC header][8 bytes byte_len][8 bytes char_len][data...]
            # $reg points to the START of the string object (the GC header).
            # Data starts at $reg + 24. Length is at $reg + 8.
            
            $jit_as->mov_reg( 'rsi', $reg );
            $jit_as->add_imm( 'rsi', 24 ); # Skip metadata
            $jit_as->load_reg_mem( 'rdx', $reg, 8 ); # Load byte_len
            
            if ( $os eq 'win64' ) {
                $self->_win32_write_stdout($jit_as);
            }
            elsif ( $os eq 'linux' ) {
                $self->_linux_syscall_write($jit_as, 1);
            }
            elsif ( $os eq 'darwin' ) {
                $self->_darwin_syscall_write($jit_as, 1);
            }
        }

        method _jit_emit_char($jit_as, $reg) {
            $jit_as->sub_imm('rsp', 16);
            $jit_as->store_mem_disp_byte( 'rsp', 0, $reg );
            $jit_as->mov_reg( 'rsi', 'rsp' );
            $jit_as->mov_imm( 'rdx', 1 );
            if ( $os eq 'win64' ) {
                $self->_win32_write_stdout($jit_as);
            }
            elsif ( $os eq 'linux' ) {
                $self->_linux_syscall_write($jit_as, 1);
            }
            elsif ( $os eq 'darwin' ) {
                $self->_darwin_syscall_write($jit_as, 1);
            }
            $jit_as->add_imm('rsp', 16);
        }

        field %runtime_cache;

        method _invoke($ptr) {
            # Pure JIT-based FFI (Self-hosting)
            # We use dl_install_xsub as a CORE mechanism to enter the machine code world.
            # Once inside, we can call anything.
            warn "JIT: Invoking code at " . sprintf("0x%X", $ptr) . "...\n" if $ENV{BROCKEN_JIT_DEBUG};
            
            my $sub_name = "Brocken::JIT::XSUB_" . ++$xsub_idx;
            require DynaLoader;
            DynaLoader::dl_install_xsub($sub_name, $ptr, "J");
            no strict 'refs';
            my $res = $sub_name->();
            warn "JIT: Code returned " . ($res // 'undef') . "\n" if $ENV{BROCKEN_JIT_DEBUG};
            return $res;
        }

        method _bootstrap_runtime() {
            return if %runtime_cache;
            warn "JIT: Bootstrapping runtime...\n" if $ENV{BROCKEN_JIT_DEBUG};
            
            if ($os eq 'win64') {
                # 1. Find Kernel32 base via PEB
                # mov rax, gs:[0x60] -> Ldr -> InMemoryOrderModuleList
                my $peb_as = $self->_create_assembler();
                $peb_as->append_code(pack("C*", 0x65, 0x48, 0x8B, 0x04, 0x25, 0x60, 0x00, 0x00, 0x00)); # mov rax, gs:[60]
                $peb_as->append_code(pack("C*", 0x48, 0x8B, 0x40, 0x18)); # mov rax, [rax+18]
                $peb_as->append_code(pack("C*", 0x48, 0x8B, 0x40, 0x20)); # mov rax, [rax+20]
                $peb_as->append_code(pack("C*", 0x48, 0x8B, 0x00));       # pModule (Perl.exe)
                $peb_as->append_code(pack("C*", 0x48, 0x8B, 0x00));       # ntdll.dll
                $peb_as->append_code(pack("C*", 0x48, 0x8B, 0x00));       # kernel32.dll
                $peb_as->append_code(pack("C*", 0x48, 0x8B, 0x40, 0x20)); # DllBase
                $peb_as->ret();
                
                my $peb_raw = $peb_as->code;
                my $peb_exec = $self->_make_executable(\$peb_raw);
                warn "JIT: PEB walker at " . sprintf("0x%X", $peb_exec->{addr}) . "\n" if $ENV{BROCKEN_JIT_DEBUG};
                my $k32_base = $self->_invoke($peb_exec->{addr});
                die "Failed to find kernel32.dll base" unless $k32_base;
                warn "JIT: Kernel32 base found at " . sprintf("0x%X", $k32_base) . "\n" if $ENV{BROCKEN_JIT_DEBUG};
                
                $runtime_cache{kernel32_base} = $k32_base;
                $runtime_cache{GetProcAddress} = $self->_find_export_pure_perl($k32_base, "GetProcAddress");
                $runtime_cache{LoadLibraryA}   = $self->_find_export_pure_perl($k32_base, "LoadLibraryA");
            }
        }

        method _find_symbol_jit($jit_as, $dll_name, $symbol_name) {
            warn "JIT: Finding symbol $symbol_name in $dll_name...\n" if $ENV{BROCKEN_JIT_DEBUG};
            $self->_bootstrap_runtime();
            
            state %addr_cache;
            my $key = "$dll_name:$symbol_name";
            return $addr_cache{$key} if $addr_cache{$key};

            if ($os eq 'win64') {
                my $dll_base;
                if ($dll_name eq 'kernel32.dll') {
                    $dll_base = $runtime_cache{kernel32_base};
                } else {
                    # Call LoadLibraryA via JIT trampoline
                    my $ll_as = $self->_create_assembler();
                    # Save some regs if needed, but this is a fresh JIT snippet
                    $ll_as->mov_imm('rcx', unpack('Q', pack('P', $dll_name . "\0")));
                    $ll_as->mov_imm('rax', $runtime_cache{LoadLibraryA});
                    $ll_as->sub_imm('rsp', 32); # Shadow space
                    $ll_as->call_reg('rax');
                    $ll_as->add_imm('rsp', 32);
                    $ll_as->ret();
                    
                    my $ll_raw = $ll_as->code;
                    my $ll_exec = $self->_make_executable(\$ll_raw);
                    $dll_base = $self->_invoke($ll_exec->{addr});
                    die "Failed to load $dll_name" unless $dll_base;
                }
                
                # Call GetProcAddress via JIT trampoline
                my $gpa_as = $self->_create_assembler();
                $gpa_as->mov_imm('rcx', $dll_base);
                $gpa_as->mov_imm('rdx', unpack('Q', pack('P', $symbol_name . "\0")));
                $gpa_as->mov_imm('rax', $runtime_cache{GetProcAddress});
                $gpa_as->sub_imm('rsp', 32);
                $gpa_as->call_reg('rax');
                $gpa_as->add_imm('rsp', 32);
                $gpa_as->ret();
                
                my $gpa_raw = $gpa_as->code;
                my $gpa_exec = $self->_make_executable(\$gpa_raw);
                my $addr = $self->_invoke($gpa_exec->{addr});
                return $addr_cache{$key} = $addr;
            }
            
            # Non-Windows still uses DynaLoader for now
            require DynaLoader;
            my $lib = DynaLoader::dl_load_file(undef);
            return $addr_cache{$key} = DynaLoader::dl_find_symbol($lib, $symbol_name);
        }

        method _find_export_pure_perl($base, $name) {
            # Use unpack 'P' to read memory at $base
            my $read_q = sub { unpack("Q", pack("P", shift)) };
            my $read_l = sub { unpack("L", pack("P", shift)) };
            my $read_s = sub { unpack("S", pack("P", shift)) };
            
            # DOS Header
            my $e_lfanew = $read_l->($base + 0x3C);
            my $nt_header = $base + $e_lfanew;
            
            # Export Table is at DataDirectory[0]
            # OptionalHeader starts at $nt_header + 4 (Signature) + 20 (FileHeader)
            my $export_rva = $read_l->($nt_header + 24 + 112);
            my $export_dir = $base + $export_rva;
            
            my $num_names = $read_l->($export_dir + 24);
            my $addr_names = $base + $read_l->($export_dir + 32);
            my $addr_funcs = $base + $read_l->($export_dir + 28);
            my $addr_ords  = $base + $read_l->($export_dir + 36);
            
            for (my $i = 0; $i < $num_names; $i++) {
                my $name_rva = $read_l->($addr_names + $i * 4);
                # Read string at $base + $name_rva
                my $n = "";
                my $curr = $base + $name_rva;
                while (1) {
                    my $c = unpack("C", pack("P", $curr++));
                    last if $c == 0;
                    $n .= chr($c);
                }
                if ($n eq $name) {
                    my $ord = $read_s->($addr_ords + $i * 2);
                    my $func_rva = $read_l->($addr_funcs + $ord * 4);
                    return $base + $func_rva;
                }
            }
            die "Symbol $name not found in DLL";
        }

        method _jit_emit_alloc($jit_as, $size, $dest_reg) {
            my $alloc_addr = $self->_find_symbol_jit($jit_as, "msvcrt.dll", "malloc");
            
            my $arg_reg = ($os eq 'win64' ? 'rcx' : 'rdi');
            if ($size =~ /^-?\d+$/) {
                $jit_as->mov_imm($arg_reg, $size);
            } else {
                $jit_as->mov_reg($arg_reg, $size);
            }

            $jit_as->mov_imm('rax', $alloc_addr);
            $jit_as->sub_imm('rsp', 32) if $os eq 'win64';
            $jit_as->call_reg('rax');
            $jit_as->add_imm('rsp', 32) if $os eq 'win64';
            $jit_as->mov_reg($dest_reg, 'rax') if $dest_reg;
        }

        method _jit_emit_call_native($jit_as, $reg_map, $inst, $lib_name, $sym_name, $sig, $args, $ds) {
            my $addr = $self->_find_symbol_jit($jit_as, $lib_name, $sym_name);
            my $dest_reg = exists $reg_map->{ $inst->{dest} } ? $reg_map->{ $inst->{dest} } : undef;

            # Simple ABI handling for now (mostly integers/pointers)
            my @regs = ($os eq 'win64') ? qw(rcx rdx r8 r9) : qw(rdi rsi rdx rcx r8 r9);
            
            for my $i (0 .. $#$args) {
                my $arg = $args->[$i];
                my $src = ($arg =~ /^%/) ? $reg_map->{$arg} : 'r11';
                
                # If immediate, move to scratch
                if ($arg !~ /^%/) {
                    my $val = 0;
                    if ($arg =~ /^-?\d+$/) {
                        $val = $arg;
                    }
                    $jit_as->mov_imm('r11', $val);
                }

                # Unbox Brocken Smi if it's an Int
                # Brocken Int: (val << 1) | 1
                # To unbox: shr reg, 1
                if ($arg =~ /^%/) {
                    # We might need to copy to scratch before unboxing to avoid destroying the register value
                    $jit_as->mov_reg('r10', $src);
                    $jit_as->shr_imm('r10', 1);
                    $src = 'r10';
                }

                if ($i < scalar(@regs)) {
                    $jit_as->mov_reg($regs[$i], $src);
                } else {
                    # Stack arguments
                    $jit_as->store_mem_disp_reg('rsp', ($i - scalar(@regs)) * 8 + ($os eq 'win64' ? 32 : 0), $src);
                }
            }

            $jit_as->mov_imm('rax', $addr);
            $jit_as->sub_imm('rsp', 32) if $os eq 'win64';
            $jit_as->call_reg('rax');
            $jit_as->add_imm('rsp', 32) if $os eq 'win64';

            # Box return value if needed
            # For now assume it's an Int
            # To box: (rax << 1) | 1
            if ($dest_reg) {
                $jit_as->shl_imm('rax', 1);
                $jit_as->or_imm('rax', 1);
                $jit_as->mov_reg($dest_reg, 'rax');
            }
        }

        method _win32_write_stdout($jit_as) {
            my $GetStdHandle_addr = $self->_find_symbol_jit($jit_as, "kernel32.dll", "GetStdHandle");
            my $WriteFile_addr    = $self->_find_symbol_jit($jit_as, "kernel32.dll", "WriteFile");

            # RSI: buffer, RDX: len
            $jit_as->push_reg('rsi');
            $jit_as->push_reg('rdx');

            # GetStdHandle(-11)
            $jit_as->mov_imm('rcx', -11);
            $jit_as->mov_imm('rax', $GetStdHandle_addr);
            $jit_as->sub_imm('rsp', 32); 
            $jit_as->call_reg('rax');
            $jit_as->add_imm('rsp', 32);
            
            # Now RAX = handle
            $jit_as->mov_reg('rcx', 'rax');
            $jit_as->pop_reg('r8');  # original RDX (len)
            $jit_as->pop_reg('rdx'); # original RSI (buffer)

            # WriteFile(RCX, RDX, R8, R9, [stack])
            $jit_as->sub_imm('rsp', 48);
            $jit_as->lea_reg_disp('r9', 'rsp', 40); # &written
            $jit_as->mov_imm('rax', 0);
            $jit_as->store_mem_disp_reg('rsp', 32, 'rax'); # overlapped = 0
            
            $jit_as->mov_imm('rax', $WriteFile_addr);
            $jit_as->call_reg('rax');
            $jit_as->add_imm('rsp', 48);
        }

        method _jit_emit_op($jit_as, $reg_map, $inst, $dest_reg, $ds, $driver) {
            my $op = $inst->{op};
            my $v = sub {
                my $x = shift;
                return 0 unless defined $x;
                return $reg_map->{$x} if exists $reg_map->{$x};
                return $x if $x =~ /^-?\d+$/;
                return 0;
            };

            if ( $op eq 'constant' ) {
                $jit_as->mov_imm( $dest_reg, $inst->{args}[0] );
            }
            elsif ( $op eq 'mov' ) {
                my $src = $inst->{args}[0];
                if ( $src =~ /^%/ ) { $jit_as->mov_reg( $dest_reg, $reg_map->{$src} ); }
                else                { $jit_as->mov_imm( $dest_reg, $v->($src) ); }
            }
            elsif ( $op =~ /^(add|sub|and|or|xor)$/ ) {
                my ($l, $r) = @{$inst->{args}};
                if ($l =~ /^%/) { $jit_as->mov_reg($dest_reg, $reg_map->{$l}); }
                else            { $jit_as->mov_imm($dest_reg, $v->($l)); }
                
                if ($r =~ /^%/) {
                    my $meth = "${op}_reg";
                    $jit_as->$meth($dest_reg, $reg_map->{$r});
                } else {
                    my $meth = "${op}_imm";
                    $jit_as->$meth($dest_reg, $v->($r));
                }
            }
            elsif ( $op eq 'mul' ) {
                my ($l, $r) = @{$inst->{args}};
                if ($l =~ /^%/) { $jit_as->mov_reg('rax', $reg_map->{$l}); }
                else            { $jit_as->mov_imm('rax', $v->($l)); }
                
                if ($r =~ /^%/) { $jit_as->mul_reg($reg_map->{$r}); }
                else            { $jit_as->mov_imm('r11', $v->($r)); $jit_as->mul_reg('r11'); }
                $jit_as->mov_reg($dest_reg, 'rax');
            }
            elsif ( $op =~ /^(div|mod)$/ ) {
                my ($l, $r) = @{$inst->{args}};
                if ($l =~ /^%/) { $jit_as->mov_reg('rax', $reg_map->{$l}); }
                else            { $jit_as->mov_imm('rax', $v->($l)); }
                $jit_as->mov_imm('rdx', 0);
                
                if ($r =~ /^%/) { $jit_as->idiv_reg($reg_map->{$r}); }
                else            { $jit_as->mov_imm('r11', $v->($r)); $jit_as->idiv_reg('r11'); }
                $jit_as->mov_reg($dest_reg, ($op eq 'div' ? 'rax' : 'rdx'));
            }
            elsif ( $op =~ /^cmp_(eq|ne|lt|le|gt|ge)$/ ) {
                my ($l, $r) = @{$inst->{args}};
                if ($l =~ /^%/) { $jit_as->mov_reg('r10', $reg_map->{$l}); }
                else            { $jit_as->mov_imm('r10', $v->($l)); }
                
                if ($r =~ /^%/) { $jit_as->cmp_reg_reg('r10', $reg_map->{$r}); }
                else            { $jit_as->cmp_reg_imm('r10', $v->($r)); }
                
                my $cc = { eq => 0x94, ne => 0x95, lt => 0x9C, gt => 0x9F, le => 0x9E, ge => 0x9D }->{substr($op, 4)};
                $jit_as->setcc($cc, $dest_reg);
                $jit_as->and_imm($dest_reg, 1); # Ensure it's 0 or 1
            }
            elsif ( $op =~ /^(shl|shr)$/ ) {
                my ($l, $r) = @{$inst->{args}};
                if ($l =~ /^%/) { $jit_as->mov_reg($dest_reg, $reg_map->{$l}); }
                else            { $jit_as->mov_imm($dest_reg, $v->($l)); }
                
                if ($r =~ /^%/) { $jit_as->mov_reg('rcx', $reg_map->{$r}); $jit_as->${\($op . "_cl")}($dest_reg); }
                else            { $jit_as->${\($op . "_imm")}($dest_reg, $v->($r)); }
            }
            elsif ( $op eq 'load_mem_disp' ) {
                $jit_as->load_reg_mem($dest_reg, $reg_map->{$inst->{args}[0]}, $inst->{args}[1]);
            }
            elsif ( $op eq 'store_mem_disp' ) {
                my $src = ($inst->{args}[2] =~ /^%/) ? $reg_map->{$inst->{args}[2]} : 'r11';
                $jit_as->mov_imm('r11', $v->($inst->{args}[2])) if $inst->{args}[2] !~ /^%/;
                $jit_as->store_mem_disp_reg($reg_map->{$inst->{args}[0]}, $inst->{args}[1], $src);
            }
            elsif ( $op eq 'load_mem_byte' ) {
                $jit_as->load_reg_mem_byte($dest_reg, $reg_map->{$inst->{args}[0]}, $inst->{args}[1]);
            }
            elsif ( $op eq 'store_mem_byte' ) {
                my $src = ($inst->{args}[2] =~ /^%/) ? $reg_map->{$inst->{args}[2]} : 'r11';
                $jit_as->mov_imm('r11', $v->($inst->{args}[2])) if $inst->{args}[2] !~ /^%/;
                $jit_as->store_mem_disp_byte($reg_map->{$inst->{args}[0]}, $inst->{args}[1], $src);
            }
            elsif ( $op eq 'local_load' ) {
                $jit_as->load_reg_mem($dest_reg, 'rbp', -$inst->{args}[0]);
            }
            elsif ( $op eq 'local_store' ) {
                my $src = ($inst->{args}[1] =~ /^%/) ? $reg_map->{$inst->{args}[1]} : 'r11';
                $jit_as->mov_imm('r11', $v->($inst->{args}[1])) if $inst->{args}[1] !~ /^%/;
                $jit_as->store_mem_disp_reg('rbp', -$inst->{args}[0], $src);
            }
            elsif ( $op eq 'enter_func' ) {
                $jit_as->push_reg('rbp');
                $jit_as->mov_reg('rbp', 'rsp');
                $jit_as->sub_imm('rsp', 1024 + 64); # Fixed large frame for JIT
            }
            elsif ( $op eq 'leave_func' || $op eq 'ret' ) {
                if (defined $inst->{args}[0]) {
                    if ($inst->{args}[0] =~ /^%/) { $jit_as->mov_reg('rax', $reg_map->{$inst->{args}[0]}); }
                    else                          { $jit_as->mov_imm('rax', $v->($inst->{args}[0])); }
                }
                $jit_as->mov_reg('rsp', 'rbp');
                $jit_as->pop_reg('rbp');
                $jit_as->ret();
            }
            elsif ( $op eq 'call_func' ) {
                my @args = @{$inst->{args}};
                my $target = shift @args;
                my @regs = ($os eq 'win64') ? qw(rcx rdx r8 r9) : qw(rdi rsi rdx rcx r8 r9);
                for my $i (0 .. $#args) {
                    my $src = ($args[$i] =~ /^%/) ? $reg_map->{$args[$i]} : 'r11';
                    $jit_as->mov_imm('r11', $v->($args[$i])) if $args[$i] !~ /^%/;
                    if ($i < scalar(@regs)) { $jit_as->mov_reg($regs[$i], $src); }
                    else        { $jit_as->store_mem_disp_reg('rsp', ($i-scalar(@regs))*8 + ($os eq 'win64' ? 32 : 0), $src); }
                }
                $jit_as->call_label($target);
                $jit_as->mov_reg($dest_reg, 'rax') if $dest_reg;
            }
            elsif ( $op eq 'call_reg' ) {
                my @args = @{$inst->{args}};
                my $fn_reg = $reg_map->{shift @args};
                my @regs = ($os eq 'win64') ? qw(rcx rdx r8 r9) : qw(rdi rsi rdx rcx r8 r9);
                for my $i (0 .. $#args) {
                    my $src = ($args[$i] =~ /^%/) ? $reg_map->{$args[$i]} : 'r11';
                    $jit_as->mov_imm('r11', $v->($args[$i])) if $args[$i] !~ /^%/;
                    if ($i < scalar(@regs)) { $jit_as->mov_reg($regs[$i], $src); }
                    else        { $jit_as->store_mem_disp_reg('rsp', ($i-scalar(@regs))*8 + ($os eq 'win64' ? 32 : 0), $src); }
                }
                $jit_as->call_reg($fn_reg);
                $jit_as->mov_reg($dest_reg, 'rax') if $dest_reg;
            }
            elsif ( $op eq 'get_arg' ) {
                my $idx = $inst->{args}[0];
                my @regs = ($os eq 'win64') ? qw(rcx rdx r8 r9) : qw(rdi rsi rdx rcx r8 r9);
                if ($idx < scalar(@regs)) {
                    $jit_as->mov_reg($dest_reg, $regs[$idx]);
                } else {
                    die "Stack arguments not yet supported in JIT";
                }
            }
            elsif ( $op eq 'get_isolate_ctx' ) {
                $jit_as->mov_reg($dest_reg, 'r14');
            }
            elsif ( $op eq 'set_isolate_ctx' ) {
                $jit_as->mov_reg('r14', $reg_map->{$inst->{args}[0]});
            }
            elsif ( $op eq 'load_iso_disp' ) {
                $jit_as->load_reg_mem($dest_reg, 'r14', $inst->{args}[0]);
            }
            elsif ( $op eq 'store_iso_disp' ) {
                my $src = ($inst->{args}[1] =~ /^%/) ? $reg_map->{$inst->{args}[1]} : 'r11';
                $jit_as->mov_imm('r11', $v->($inst->{args}[1])) if $inst->{args}[1] !~ /^%/;
                $jit_as->store_mem_disp_reg('r14', $inst->{args}[0], $src);
            }
            elsif ( $op =~ /^shadow_(get|set|restore)$/ ) {
                $jit_as->load_reg_mem( 'r11', 'r14', $driver->iso_offset('current_fcb') );
                if ( $op eq 'shadow_get' ) { $jit_as->load_reg_mem( $dest_reg, 'r11', $driver->fcb_offset('shadow_ptr') ); }
                else {
                    my $src = ($inst->{args}[0] =~ /^%/) ? $reg_map->{$inst->{args}[0]} : 'r10';
                    $jit_as->mov_imm('r10', $v->($inst->{args}[0])) if $inst->{args}[0] !~ /^%/;
                    $jit_as->store_mem_disp_reg('r11', $driver->fcb_offset('shadow_ptr'), $src);
                }
            }
            elsif ( $op eq 'shadow_push' ) {
                $jit_as->load_reg_mem( 'r11', 'r14', $driver->iso_offset('current_fcb') );
                $jit_as->load_reg_mem( 'r10', 'r11', $driver->fcb_offset('shadow_ptr') );
                my $src = ($inst->{args}[0] =~ /^%/) ? $reg_map->{$inst->{args}[0]} : 'r9';
                $jit_as->mov_imm('r9', $v->($inst->{args}[0])) if $inst->{args}[0] !~ /^%/;
                $jit_as->store_mem_disp_reg('r10', 0, $src);
                $jit_as->add_imm('r10', 8);
                $jit_as->store_mem_disp_reg('r11', $driver->fcb_offset('shadow_ptr'), 'r10');
            }
            elsif ( $op eq 'load_func_addr' ) {
                $jit_as->mov_label($dest_reg, $inst->{args}[0]);
            }
            elsif ( $op eq 'load_data_addr' ) {
                my $offset = $inst->{args}[0];
                my $ds_raw = $ds->get_raw_data();
                my $base_ptr = unpack('Q', pack('P', $ds_raw));
                $jit_as->mov_imm($dest_reg, $base_ptr + $offset);
            }
        }

        method _make_executable($code_ref) {
            my $size = length($$code_ref);
            my $page_size = 4096;
            my $aligned = ( $size + $page_size - 1 ) & ~( $page_size - 1 );

            if ( $os eq 'win64' ) {
                return $self->_win32_executable($code_ref, $aligned);
            }
            else {
                return $self->_unix_executable($code_ref, $aligned);
            }
        }

        method _win32_executable($code_ref, $size) {
            require Brocken::Runtime::Memory;
            my $mem_info = Brocken::Runtime::Memory::allocate_executable($size);
            my $buf = $mem_info->{buf};
            my $code_offset = $mem_info->{offset} // 0;

            my $src = $$code_ref;
            substr($$buf, $code_offset, length($src)) = $src;

            my $ptr = unpack('Q', pack('P', $$buf)) + $code_offset;
            return {
                executable => pack('P', $ptr),
                addr       => $ptr,
                buf        => $buf,
                offset     => $code_offset
            };
        }

        method _unix_executable($code_ref, $size) {
            my $buf = "\x90" x $size;
            substr( $buf, 0, length($$code_ref) ) = $$code_ref;
            # Get address of $buf
            my $ptr = unpack('Q', pack('P', $buf));
            return {
                executable => \$buf,
                addr       => $ptr,
                buf        => \$buf,
                offset     => 0
            };
        }

        method _simple_allocate($insts) {
            my @free = qw(rax rbx rcx rdx rsi rdi r8 r9 r10 r11 r12 r13 r14 r15);
            my %rmap;
            for my $inst (@$insts) {
                next if $inst->{op} eq 'label';
                if ( defined $inst->{dest} && $inst->{dest} =~ /^%/ && !exists $rmap{ $inst->{dest} } ) {
                    $rmap{ $inst->{dest} } = shift(@free) // 'r11';
                }
                if ( $inst->{args} ) {
                    for my $arg (@{ $inst->{args} }) {
                        if ( ref($arg) eq '' && defined $arg && $arg =~ /^%/ && !exists $rmap{$arg} ) {
                            $rmap{$arg} = shift(@free) // 'r11';
                        }
                    }
                }
                if ( exists $inst->{reg} && $inst->{reg} =~ /^%/ && !exists $rmap{ $inst->{reg} } ) {
                    $rmap{ $inst->{reg} } = shift(@free) // 'r11';
                }
            }
            return %rmap;
        }

        method execute($result) {
            my $code = $result->{code};
            return $self->_call_code($code);
        }

        method _call_code($code) {
            if ( $os eq 'win64' ) {
                return $self->_win32_call($code);
            }
            else {
                return $self->_unix_call($code);
            }
        }

        method _win32_call($code) {
            my $ptr;
            {
                no warnings 'uninitialized';
                $ptr = unpack 'Q', pack 'P', $code;
            }
            return $self->_invoke($ptr);
        }

        method _unix_call($code) {
            my $ptr = unpack 'Q', substr( ${$code}, 0, 8 );
            return $self->_invoke($ptr);
        }

        sub _create_eval_driver {
            my ($arch, $os) = @_;
            $os //= $^O eq 'MSWin32' ? 'win64' : ($^O eq 'linux' ? 'linux' : 'darwin');
            $arch //= 'x64';

            require Brocken::Compiler;
            return Brocken::Compiler->new( os => $os, arch => $arch );
        }

        # Reverse trampoline: create a C-callable function pointer from a Perl coderef
        method create_reverse_trampoline($coderef, $sig = 'int(int,int)') {
            warn "Creating reverse trampoline for: $sig" if $ENV{BROCKEN_JIT_DEBUG};

            # Parse signature to determine arg handling
            my ($ret_type, @arg_types) = $self->_parse_signature($sig);

            # Create assembler
            my $jit_as = $self->_create_assembler();

            # Allocate a slot in data for the coderef pointer
            my $callback_slot = $self->_alloc_callback_slot($coderef);

            # Generate wrapper code:
            # This is a callback that receives C params, converts to Perl, calls the sub, returns C result
            $jit_as->push_reg('rbp');
            $jit_as->mov_reg('rbp', 'rsp');
            $jit_as->sub_imm('rsp', 64);  # Shadow space + locals

            # Load the callback address from our slot
            my $callback_addr_slot = $callback_slot->{addr};
            $jit_as->mov_imm('r11', $callback_addr_slot);
            $jit_as->load_reg_mem('r11', 'r11', 0);

            # Prepare args based on signature (simplified: assumes up to 4 int args)
            # For int args: box them (val << 1) | 1
            my @arg_regs = qw(rcx rdx r8 r9);
            for my $i (0..$#arg_types) {
                my $reg = $arg_regs[$i] // next;
                if ($arg_types[$i] eq 'int' || $arg_types[$i] eq 'Int') {
                    $jit_as->mov_reg('r10', $reg);
                    $jit_as->shl_imm('r10', 1);
                    $jit_as->or_imm('r10', 1);
                    $jit_as->store_mem_disp_reg('rsp', 8 + $i * 8, 'r10');
                }
            }

            # Call the callback (r11 holds the address)
            $jit_as->call_reg('r11');

            # Result is in rax - unbox if needed
            if ($ret_type eq 'int' || $ret_type eq 'Int') {
                $jit_as->shr_imm('rax', 1);
            }

            $jit_as->add_imm('rsp', 64);
            $jit_as->pop_reg('rbp');
            $jit_as->ret();

            # Make executable
            my $raw = $jit_as->code;
            my $exec_info = $self->_make_executable(\$raw);
            my $fn_ptr = $exec_info->{addr};

            warn "Reverse trampoline created at: " . sprintf("0x%X", $fn_ptr) if $ENV{BROCKEN_JIT_DEBUG};

            return $fn_ptr;
        }

        method _parse_signature($sig) {
            # Simple signature parser: "int(int,int)" -> ('int', 'int', 'int')
            if ($sig =~ /^(.+?)\((.*?)\)$/) {
                my $ret = $1;
                my @args = split /,/, $2;
                return ($ret, @args);
            }
            return ('int', 'int');  # default
        }

        field %callback_slots;
        field $callback_idx = 0;

        method _alloc_callback_slot($coderef) {
            my $idx = ++$callback_idx;
            $callback_slots{$idx} = $coderef;
            # Allocate a simple address - in real impl, this would be in the data segment
            return { addr => 0x1000 + $idx * 8, idx => $idx };
        }
    }
}
1;
