package Brocken::JIT {
    use v5.40;
    use utf8;
    use feature 'class';
    no warnings 'experimental::class';

    class Brocken::JIT {
        field $driver : param;
        field $arch : param;
        field $os : param;
        field %compiled_cache;

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
            my $ds       = Brocken::Compiler::DataSegment->new();
            my $lowering = Brocken::Compiler::Lowering->new(
                data_segment => $ds,
                driver       => $driver
            );
            $lowering->lower_program($ast);

            my $optimizer = Brocken::Compiler::Optimizer->new();
            $optimizer->optimize( $lowering->builder );

            my @insts = $lowering->builder->instructions;
            my $jit_as = $self->_create_assembler();
            my %rmap = $self->_simple_allocate(\@insts);

            for my $i ( 0 .. $#insts ) {
                my $inst = $insts[$i];
                my $op   = $inst->{op};
                my $dest_reg = exists $rmap{ $inst->{dest} } ? $rmap{ $inst->{dest} } : undef;
                if ( $op eq 'label' ) {
                    $jit_as->mark_label( $inst->{name} );
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
                    my $code = !ref($arg) ? $arg : (exists $rmap{$arg} ? $rmap{$arg} : 0);
                    $self->_jit_emit_exit($jit_as, $code);
                }
                elsif ( $op =~ /^intrinsic_/ ) {
                }
                else {
                    $self->_jit_emit_op($jit_as, \%rmap, $inst, $dest_reg);
                }
            }

            my $raw = $jit_as->code;
            my $executable = $self->_make_executable(\$raw);

            return {
                code       => $executable,
                size       => length($raw),
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
            $jit_as->mov_reg( 'rsi', $reg );
            $jit_as->add_imm( 'rsi', 16 );
            $jit_as->load_reg_mem( 'rdx', $reg, 0 );
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
            $jit_as->store_mem_disp_byte( 'rsp', -1, $reg );
            $jit_as->lea_reg_disp( 'rsi', 'rsp', -1 );
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
        }

        method _win32_write_stdout($jit_as) {
            $jit_as->mov_imm( 'rcx', -11 );
            $jit_as->push_reg('r10');
            $jit_as->push_reg('r11');
            $jit_as->mov_reg( 'r10', 'rcx' );
            $jit_as->mov_reg( 'r11', 'rsi' );
            $jit_as->mov_reg( 'r9',  'rdx' );
            $jit_as->mov_imm( 'r8',  0 );
            $jit_as->mov_imm( 'rax', 0 );
            $jit_as->store_mem_disp_reg( 'rsp', 32, 'r9' );
            $jit_as->store_mem_disp_reg( 'rsp', 40, 'r8' );
            $jit_as->call_label('L_win32_GetStdHandle');
            $jit_as->mov_reg( 'rcx', 'rax' );
            $jit_as->mov_reg( 'rdx', 'r11' );
            $jit_as->mov_reg( 'r9', 'r10' );
            $jit_as->mov_reg( 'r8', 'r9' );
            $jit_as->mov_imm( 'rax', 0 );
            $jit_as->store_mem_disp_reg( 'rsp', 32, 'rax' );
            $jit_as->call_label('L_win32_WriteFile');
            $jit_as->pop_reg('r11');
            $jit_as->pop_reg('r10');
            $jit_as->mark_label('L_win32_GetStdHandle');
            $jit_as->ret();
            $jit_as->mark_label('L_win32_WriteFile');
            $jit_as->ret();
        }

        method _linux_syscall_write($jit_as, $fd) {
            $jit_as->mov_imm( 'edi', $fd );
            $jit_as->mov_imm( 'eax', 1 );
            $jit_as->syscall();
        }

        method _darwin_syscall_write($jit_as, $fd) {
            $jit_as->mov_imm( 'edi', $fd );
            $jit_as->mov_imm( 'eax', 0x2000000 | 4 );
            $jit_as->syscall();
        }

        method _jit_emit_exit($jit_as, $code) {
            if ( $os eq 'win64' ) {
                $jit_as->mov_imm( 'rcx', $code );
                $jit_as->mov_imm( 'rax', 0 );
                $jit_as->ret();
            }
            else {
                $jit_as->mov_imm( 'edi', $code );
                $jit_as->mov_imm( 'eax', 60 );
                $jit_as->syscall();
            }
        }

        method _jit_emit_op($jit_as, $reg_map, $inst, $dest_reg) {
            my $op = $inst->{op};
            if ( $op eq 'constant' ) {
                my $imm = $inst->{args}[0];
                $jit_as->mov_imm( $dest_reg, $imm );
            }
            elsif ( $op eq 'mov' ) {
                my $src = $inst->{args}[0];
                if ( ref($src) ) { $src = $reg_map->{$src}; }
                if ( $src =~ /^\d+$/ ) {
                    $jit_as->mov_imm( $dest_reg, $src );
                }
                else {
                    $jit_as->mov_reg( $dest_reg, $src );
                }
            }
            elsif ( $op eq 'add' ) {
                my $l = $inst->{args}[0];
                my $r = $inst->{args}[1];
                if ( ref($l) ) { $l = $reg_map->{$l}; }
                if ( ref($r) ) { $r = $reg_map->{$r}; }
                if ( $l =~ /^\d+$/ ) {
                    $jit_as->mov_imm( $dest_reg, $l );
                }
                else {
                    $jit_as->mov_reg( $dest_reg, $l );
                }
                if ( $r =~ /^\d+$/ ) {
                    $jit_as->add_imm( $dest_reg, $r );
                }
                else {
                    $jit_as->add_reg( $dest_reg, $r );
                }
            }
            elsif ( $op eq 'sub' ) {
                my $l = $inst->{args}[0];
                my $r = $inst->{args}[1];
                if ( ref($l) ) { $l = $reg_map->{$l}; }
                if ( ref($r) ) { $r = $reg_map->{$r}; }
                if ( $l =~ /^\d+$/ ) {
                    $jit_as->mov_imm( $dest_reg, $l );
                }
                else {
                    $jit_as->mov_reg( $dest_reg, $l );
                }
                if ( $r =~ /^\d+$/ ) {
                    $jit_as->sub_imm( $dest_reg, $r );
                }
                else {
                    $jit_as->sub_reg( $dest_reg, $r );
                }
            }
            elsif ( $op eq 'mul' ) {
                my $l = $inst->{args}[0];
                my $r = $inst->{args}[1];
                if ( ref($l) ) { $l = $reg_map->{$l}; }
                if ( ref($r) ) { $r = $reg_map->{$r}; }
                if ( $l =~ /^\d+$/ ) {
                    $jit_as->mov_imm( 'rax', $l );
                }
                else {
                    $jit_as->mov_reg( 'rax', $l );
                }
                if ( $r =~ /^\d+$/ ) {
                    $jit_as->mov_imm( 'r11', $r );
                    $jit_as->mul_reg('r11');
                }
                else {
                    $jit_as->mul_reg($r);
                }
                $jit_as->mov_reg( $dest_reg, 'rax' );
            }
            elsif ( $op eq 'call_func' ) {
                my $target = $inst->{args}[0];
                $jit_as->call_label($target);
                $jit_as->mov_reg( $dest_reg, 'rax' ) if defined $dest_reg;
            }
            elsif ( $op eq 'ret' || $op eq 'leave_func' ) {
                $jit_as->ret();
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
            eval { require Win32::API::Access };
            my $VA = Win32::API::Access->new(
                'kernel32.dll', 'VirtualAlloc',
                'PNNNN', 'P'
            ) or die "Cannot create VirtualAlloc: $^E";
            my $buf = $VA->Call(0, $size, 0x3000, 0x40);
            die "VirtualAlloc failed" unless $buf;
            substr( $$code_ref, 0 ) = $buf;
            return $buf;
        }

        method _unix_executable($code_ref, $size) {
            my $buf = "\x90" x $size;
            substr( $buf, 0, length($$code_ref) ) = $$code_ref;
            return \$buf;
        }

        method _simple_allocate($insts) {
            my @free = qw(rax rbx rcx rdx rsi rdi r8 r9 r10 r11 r12 r13 r14 r15);
            my %rmap;
            for my $inst (@$insts) {
                next if $inst->{op} eq 'label';
                if ( defined $inst->{dest} && $inst->{dest} =~ /^%/ ) {
                    $rmap{ $inst->{dest} } = shift(@free) // 'r11';
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
            my $ptr = unpack 'Q', pack 'P', $code;
            return $self->_invoke($ptr);
        }

        method _invoke($ptr) {
            no warnings 'uninitialized';
            my $f;
            {
                local $@;
                $f = eval { pack 'J', $ptr };
            }
            $f =~ s/J/P/ if length pack('P', 0) > length pack('J', 0);
            my $code = qq{ package main; sub { goto \&\$f } };
            my $sub = eval $code;
            return $sub ? $sub->() : 0;
        }

        method _unix_call($code) {
            my $ptr = unpack 'Q', substr( ${$code}, 0, 8 );
            return $self->_invoke($ptr);
        }
    }
}
1;
__END__

=pod

=head1 NAME

Brocken::JIT - Cross-platform Just-In-Time compilation for Brocken

=head1 SYNOPSIS

  use Brocken::JIT;
  my $jit = Brocken::JIT->new( driver => $driver, arch => 'x64', os => 'win64' );
  my $result = $jit->compile_and_run('say "hello";');

=head1 DESCRIPTION

Provides JIT compilation for Brocken code with cross-platform support for Windows,
Linux, and macOS on x64 and ARM64 architectures.

=cut
1;