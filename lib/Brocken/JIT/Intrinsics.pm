package Brocken::JIT::Intrinsics {
    use v5.40;
    use utf8;
    use feature 'class';
    no warnings 'experimental::class';

    class Brocken::JIT::Intrinsics {
        field $os : param;
        field $arch : param;

        method alloc_executable($size) {
            if ( $os eq 'win64' ) {
                return $self->_win32_alloc($size);
            }
            elsif ( $os eq 'linux' ) {
                return $self->_linux_alloc($size);
            }
            elsif ( $os eq 'darwin' ) {
                return $self->_darwin_alloc($size);
            }
            die "Unsupported OS: $os";
        }

        method _win32_alloc($size) {
            eval { require Win32::API::Access };
            my $VA = Win32::API::Access->new(
                'kernel32.dll', 'VirtualAlloc',
                'PNNNN', 'P'
            ) or die "Cannot create VirtualAlloc: $^E";
            my $buf = $VA->Call(0, $size, 0x3000, 0x40);
            die "VirtualAlloc failed" unless $buf;
            return $buf;
        }

        method _linux_alloc($size) {
            my $page_size = 4096;
            my $aligned = ( $size + $page_size - 1 ) & ~( $page_size - 1 );
            my $buf = "\0" x $aligned;
            return \$buf;
        }

        method _darwin_alloc($size) {
            my $page_size = 4096;
            my $aligned = ( $size + $page_size - 1 ) & ~( $page_size - 1 );
            my $buf = "\0" x $aligned;
            return \$buf;
        }

        method emit_print_string($jit_as, $str_ptr, $str_len) {
            if ( $os eq 'win64' ) {
                $self->_emit_win32_print($jit_as, $str_ptr, $str_len);
            }
            elsif ( $os eq 'linux' ) {
                $self->_emit_linux_write($jit_as, $str_ptr, $str_len, 1);
            }
            elsif ( $os eq 'darwin' ) {
                $self->_emit_darwin_write($jit_as, $str_ptr, $str_len, 1);
            }
        }

        method _emit_win32_print($jit_as, $str_ptr, $str_len) {
            $jit_as->mov_imm( 'rcx', -11 );
            my $GetStdHandle = $self->_get_win32_addr('GetStdHandle');
            $jit_as->append_code( pack( 'C', 0xE8 ) );
            my $rel = $GetStdHandle - length( $jit_as->{code} ) - 4;
            $jit_as->append_code( pack( 'l<', $rel ) );
        }

        method _get_win32_addr($fn) {
            return 0;
        }

        method emit_exit($jit_as, $code) {
            if ( $os eq 'win64' ) {
                $jit_as->mov_imm( 'rcx', $code );
                $jit_as->mov_imm( 'rax', 0xC0000100 | ( $code & 0xFF ) );
                $jit_as->ret();
            }
            else {
                $jit_as->mov_imm( 'edi', $code );
                $jit_as->mov_imm( 'eax', 60 );
                $jit_as->syscall();
            }
        }

        method emit_prologue($jit_as) {
            $jit_as->push_reg('rbp');
            $jit_as->mov_reg( 'rbp', 'rsp' );
        }

        method emit_epilogue($jit_as, $ret_reg = 'rax') {
            $jit_as->mov_reg( 'rax', $ret_reg );
            $jit_as->mov_reg( 'rsp', 'rbp' );
            $jit_as->pop_reg('rbp');
            $jit_as->ret();
        }
    }
}
1;
__END__

=pod

=head1 NAME

Brocken::JIT::Intrinsics - Cross-platform JIT intrinsics

=head1 DESCRIPTION

Provides platform-specific JIT intrinsics for memory allocation and syscalls.

=cut
1;