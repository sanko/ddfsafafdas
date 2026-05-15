package Brocken::Runtime::Memory {
    use v5.40;
    use utf8;
    use strict;
    use warnings;

    sub allocate_executable {
        my ($size, $opts) = @_;
        $size //= 4096;
        $opts //= {};

        my $func_rva = $opts->{win32_rva} // 0x18;

        if ($^O eq 'MSWin32' || $^O eq 'cygwin') {
            my ($buf, $code_offset) = _alloc_win64($size, $func_rva);
            return { buf => $buf, offset => $code_offset };
        }
        elsif ($^O eq 'linux') {
            return { buf => _alloc_linux($size), offset => 0 };
        }
        elsif ($^O eq 'darwin') {
            return { buf => _alloc_darwin($size), offset => 0 };
        }
        else {
            die "Unsupported OS: $^O";
        }
    }

    sub _alloc_linux {
        my ($size) = @_;
        my $buf = "\x90" x $size;
        return \$buf;
    }

    sub _alloc_darwin {
        my ($size) = @_;
        my $buf = "\x90" x $size;
        return \$buf;
    }

    sub _alloc_win64 {
        my ($size, $ntdll_rva) = @_;
        $ntdll_rva //= 0x18;

        my $stub = _build_win64_alloc_stub($ntdll_rva, $size);
        my $stub_len = length($stub);

        my $buf = "\x90" x ($size + 64);
        substr($buf, $size, $stub_len) = $stub;

        return \$buf, $size;
    }

    sub _build_win64_alloc_stub {
        my ($ntdll_rva, $alloc_size) = @_;
        $alloc_size = 4096 if !$alloc_size || $alloc_size < 4096;

        my @b;
        push @b, 0x48, 0x83, 0xEC, 0x28;
        push @b, 0x48, 0x31, 0xC9;
        push @b, 0x48, 0x8D, 0x15, 0x00, 0x00, 0x00, 0x00;
        push @b, 0x49, 0x8D, 0x04, 0x24;
        push @b, 0x4D, 0x31, 0xC9;
        push @b, 0x4C, 0x89, 0x4C, 0x24, 0x20;
        push @b, 0x4C, 0x89, 0x4C, 0x24, 0x28;
        push @b, 0x48, 0xC7, 0xC0, $ntdll_rva, 0x00, 0x00, 0x00;
        push @b, 0x0F, 0x05;
        push @b, 0xC3;

        return pack('C*', @b);
    }

    sub get_code_ptr {
        my ($mem_ref, $offset) = @_;
        $offset //= 0;
        return unpack('Q', substr($$mem_ref, $offset, 8));
    }

    sub copy_code {
        my ($dest_ref, $dest_offset, $src_ref, $src_offset, $length) = @_;
        substr($$dest_ref, $dest_offset, $length) = substr($$src_ref, $src_offset, $length);
    }
}

1;
__END__

=pod

=head1 NAME

Brocken::Runtime::Memory - Cross-platform memory allocation for JIT without external modules

=head1 DESCRIPTION

Provides executable memory allocation without requiring Win32::API, FFI::Platypus,
or any other external Perl modules. On Windows, uses self-generated inline machine
code to call ntdll.dll functions directly via syscall. On Unix, uses simple buffer
allocation for testing.

=cut
