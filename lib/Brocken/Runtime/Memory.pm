package Brocken::Runtime::Memory {
    use v5.40;
    use utf8;
    use Affix;
    require DynaLoader;

    sub allocate_executable {
        my ($size) = @_;
        $size = ($size + 4095) & ~4095;
        my $ptr;


        if ( $^O eq 'MSWin32' ) {
            # Real Affix Syntax:
            affix( 'kernel32.dll', 'VirtualAlloc',
                [ Pointer[Void], Size_t, ULong, ULong ] => Pointer[Void]
            );
            $ptr = VirtualAlloc( undef, $size, 0x3000, 0x40 );
        }
        else {
            # Real Affix Syntax:
            affix( undef, 'mmap',
                [ Pointer[Void], Size_t, Int, Int, Int, Long ] => Pointer[Void]
            );
            $ptr = mmap( undef, $size, 7, 0x22, -1, 0 );
            $ptr = 0 if $ptr == -1;
        }

        die "Brocken Critical: Executable memory allocation failed" unless $ptr;
        return { addr => $ptr, size => $size };
    }

    sub copy_to_ptr {
        my ($dest_ptr, $data) = @_;
        return unless length($data);

        state $memcpy_sub;
        unless ($memcpy_sub) {
            my $lib = DynaLoader::dl_load_file($^O eq 'MSWin32' ? "ntdll.dll" : undef);
            my $sym = DynaLoader::dl_find_symbol($lib, $^O eq 'MSWin32' ? "RtlCopyMemory" : "memcpy");
            die "Brocken Critical: Could not find memcpy" unless $sym;
            $memcpy_sub = "Brocken::Memory::Memcpy_" . int(rand(100000));
            DynaLoader::dl_install_xsub($memcpy_sub, $sym, __FILE__);
        }

        # Safe extraction of the source pointer from a Perl scalar
        my $src_ptr = unpack('Q', pack('p', $data));
        no strict 'refs';
        $memcpy_sub->($dest_ptr, $src_ptr, length($data));
    }
}
1;
