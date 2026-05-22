use v5.40;
use feature 'class';
no warnings 'experimental::class';

class Brocken::Platform::Linux : isa(Brocken::Platform) {
    method format_name() {'ELF'}

    method emit_intrinsic( $target, $as, $inst, $reg_map, $driver ) {
        my $op   = $inst->{op};
        my $v    = sub { $target->val( $reg_map, shift ) };
        my $arch = $driver->arch;
        if ( $op eq 'intrinsic_alloc' ) {
            my $d = $reg_map->{ $inst->{dest} };
            if ( $arch eq 'x64' ) {
                $as->mov_imm( 'rax', 9 );    # mmap
                $as->mov_imm( 'rdi', 0 );
                if ( $inst->{args}[0] =~ /^%/ ) { $as->mov_reg( 'rsi', $reg_map->{ $inst->{args}[0] } ); }
                else                            { $as->mov_imm( 'rsi', $v->( $inst->{args}[0] ) ); }
                $as->mov_imm( 'rdx', 3 );       # PROT_READ | PROT_WRITE
                $as->mov_imm( 'r10', 0x22 );    # MAP_PRIVATE | MAP_ANONYMOUS
                $as->mov_imm( 'r8',  -1 );
                $as->mov_imm( 'r9',  0 );
                $as->syscall();
                $as->mov_reg( $d, 'rax' );
            }
            else {
                # ARM64
                $as->mov_imm( 'x8', 222 );      # mmap
                $as->mov_imm( 'x0', 0 );        # addr
                if ( $inst->{args}[0] =~ /^%/ ) { $as->mov_reg( 'x1', $reg_map->{ $inst->{args}[0] } ); }
                else                            { $as->mov_imm( 'x1', $v->( $inst->{args}[0] ) ); }
                $as->mov_imm( 'x2', 3 );        # prot
                $as->mov_imm( 'x3', 0x22 );     # flags
                $as->mov_imm( 'x4', -1 );       # fd
                $as->mov_imm( 'x5', 0 );        # off
                $as->syscall();
                $as->mov_reg( $d, 'x0' );
            }
        }
        elsif ( $op eq 'intrinsic_get_pid' ) {
            my $d = $reg_map->{ $inst->{dest} };
            if ( $arch eq 'x64' ) {
                $as->mov_imm( 'rax', 39 );      # sys_getpid
                $as->syscall();
                $as->mov_reg( $d, 'rax' );
            }
            else {
                # ARM64: sys_getpid is 172
                $as->mov_imm( 'x8', 172 );
                $as->syscall(1);
                $as->mov_reg( $d, 'x0' );
            }
        }
        elsif ( $op eq 'intrinsic_get_system_filetime' ) {
            my $d = $reg_map->{ $inst->{dest} };
            if ( $arch eq 'x64' ) {
                $as->sub_imm( 'rsp', 16 );     # space for struct timespec (16 bytes)
                $as->mov_imm( 'rax', 228 );    # sys_clock_gettime
                $as->mov_imm( 'rdi', 0 );      # CLOCK_REALTIME
                $as->mov_reg( 'rsi', 'rsp' );
                $as->syscall();
                $as->load_reg_mem( 'rax', 'rsp', 0 );    # rax = tv_sec (Unix epoch seconds)
                $as->add_imm( 'rsp', 16 );

                # Scale to Windows FILETIME structure: epoch * 10000000 + 116444736000000000
                $as->mov_imm( 'r10', 10000000 );
                $as->mul_reg( 'rax', 'r10' );
                $as->mov_imm( 'r11', 116444736000000000 );
                $as->add_reg( 'rax', 'r11' );
                $as->mov_reg( $d, 'rax' );
            }
            else {
                # ARM64: sys_clock_gettime is 113
                $as->sub_imm( 'sp', 16 );
                $as->mov_imm( 'x8', 113 );
                $as->mov_imm( 'x0', 0 );     # CLOCK_REALTIME
                $as->mov_reg( 'x1', 'sp' );
                $as->syscall(1);
                $as->load_reg_mem( 'x0', 'sp', 0 );    # x0 = tv_sec
                $as->add_imm( 'sp', 16 );
                $as->mov_imm( 'x16', 10000000 );
                $as->mul_reg( 'x0', 'x0', 'x16' );
                $as->mov_imm( 'x17', 116444736000000000 );
                $as->add_reg( 'x0', 'x0', 'x17' );
                $as->mov_reg( $d, 'x0' );
            }
        }
        elsif ( $op eq 'intrinsic_get_module_filename' ) {
            my $d    = $reg_map->{ $inst->{dest} };
            my $buf  = $reg_map->{ $inst->{args}[0] };
            my $val1 = unpack( 'Q<', "/proc/se" );
            my $val2 = unpack( 'Q<', "lf/exe\0\0" );
            if ( $arch eq 'x64' ) {
                $as->sub_imm( 'rsp', 16 );
                $as->mov_imm( 'r10', $val2 );
                $as->store_mem_disp_reg( 'rsp', 8, 'r10' );
                $as->mov_imm( 'r10', $val1 );
                $as->store_mem_disp_reg( 'rsp', 0, 'r10' );
                $as->mov_imm( 'rax', 89 );       # sys_readlink
                $as->mov_reg( 'rdi', 'rsp' );    # pathname
                $as->mov_reg( 'rsi', $buf );     # buf
                $as->mov_imm( 'rdx', 512 );      # bufsiz
                $as->syscall();
                $as->add_imm( 'rsp', 16 );
                $as->mov_reg( $d, 'rax' );
            }
            else {
                # ARM64: readlinkat is 78
                # readlinkat(AT_FDCWD, pathname, buf, bufsiz)
                $as->sub_imm( 'sp', 16 );
                $as->mov_imm( 'x16', $val2 );
                $as->store_mem_disp_reg( 'sp', 8, 'x16' );
                $as->mov_imm( 'x16', $val1 );
                $as->store_mem_disp_reg( 'sp', 0, 'x16' );
                $as->mov_imm( 'x8',  78 );     # sys_readlinkat
                $as->mov_imm( 'x0', -100 );    # AT_FDCWD
                $as->mov_reg( 'x1', 'sp' );    # pathname
                $as->mov_reg( 'x2', $buf );    # buf
                $as->mov_imm( 'x3', 512 );     # bufsiz
                $as->syscall(1);
                $as->add_imm( 'sp', 16 );
                $as->mov_reg( $d, 'x0' );
            }
        }
        elsif ( $op eq 'intrinsic_get_cmd_line' ) {
            my $d = $reg_map->{ $inst->{dest} };
            $as->mov_imm( $d, 0 );
        }
        elsif ( $op eq 'intrinsic_get_stdout_handle' ) {
            my $d = $reg_map->{ $inst->{dest} };
            $as->mov_imm( $d, 1 );
        }
        elsif ( $op eq 'intrinsic_get_stderr_handle' ) {
            my $d = $reg_map->{ $inst->{dest} };
            $as->mov_imm( $d, 2 );
        }
        elsif ( $op eq 'intrinsic_get_stdin_handle' ) {
            my $d = $reg_map->{ $inst->{dest} };
            $as->mov_imm( $d, 0 );
        }
        elsif ( $op eq 'intrinsic_print' ) {
            my $p = $reg_map->{ $inst->{args}[0] };
            if ( $arch eq 'x64' ) {
                $as->mov_reg( 'rsi', $p );
                $as->load_reg_mem( 'rdx', 'rsi', 0 );
                $as->add_imm( 'rsi', 16 );
                $as->mov_imm( 'rdi', 1 );
                $as->mov_imm( 'rax', 1 );
                $as->syscall();
            }
            else {
                $as->mov_reg( 'x1', $p );
                $as->ldur_reg_mem( 'x2', 'x1', 0 );
                $as->add_imm( 'x1', 16 );
                $as->mov_imm( 'x0', 1 );
                $as->mov_imm( 'x8', 64 );    # write
                $as->syscall();
            }
        }
        elsif ( $op eq 'intrinsic_print_char' ) {
            my $char = $v->( $inst->{args}[0] );
            if ( $arch eq 'x64' ) {
                my $src = ( $inst->{args}[0] =~ /^%/ ) ? $reg_map->{ $inst->{args}[0] } : 'r11';
                $as->mov_imm( 'r11', $char ) if $inst->{args}[0] !~ /^%/;
                $as->store_mem_disp_byte( 'rsp', 48, $src );
                $as->mov_imm( 'rax', 1 );
                $as->mov_imm( 'rdi', 1 );
                $as->append_code( pack( 'CCCC', 0x48, 0x8D, 0x74, 0x24 ) . pack( 'C', 48 ) );    # lea rsi, [rsp+48]
                $as->mov_imm( 'rdx', 1 );
                $as->syscall();
            }
            else {
                my $src = ( $inst->{args}[0] =~ /^%/ ) ? $reg_map->{ $inst->{args}[0] } : 'x16';
                $as->mov_imm( 'x16', $char ) if $inst->{args}[0] !~ /^%/;
                $as->sturb_mem_disp_reg( 'sp', 48, $src );
                $as->mov_imm( 'x8', 64 );
                $as->mov_imm( 'x0', 1 );
                $as->add_imm( 'x16', 0 );                                                        # dummy to get SP
                $as->mov_reg( 'x1', 'sp' );
                $as->add_imm( 'x1', 48 );
                $as->mov_imm( 'x2', 1 );
                $as->syscall();
            }
        }
        elsif ( $op eq 'intrinsic_open' ) {
            my ( $path, $mode ) = ( $reg_map->{ $inst->{args}[0] }, $reg_map->{ $inst->{args}[1] } );
            state $open_id = 0;
            my $l_write = "intr_open_write_" . ++$open_id;
            my $l_call  = "intr_open_call_" . $open_id;
            if ( $arch eq 'x64' ) {
                $as->mov_reg( 'rdi', $path );
                $as->add_imm( 'rdi', 16 );
                $as->load_reg_mem_byte( 'rax', $mode, 16 );
                $as->cmp_reg_imm( 'rax', ord('r') );
                $as->jcc( $driver->cc('ne'), $l_write );
                $as->mov_imm( 'rsi', 0 );    # O_RDONLY
                $as->mov_imm( 'rdx', 0 );
                $as->jmp($l_call);
                $as->mark_label($l_write);

                # O_WRONLY (1) | O_CREAT (64) | O_TRUNC (512) = 577 = 0x241
                $as->mov_imm( 'rsi', 0x241 );
                $as->mov_imm( 'rdx', 0644 );
                $as->mark_label($l_call);
                $as->mov_imm( 'rax', 2 );    # sys_open
                $as->syscall();
                $as->mov_reg( $reg_map->{ $inst->{dest} }, 'rax' );
            }
            else {
                # ARM64 sys_openat
                $as->mov_reg( 'x1', $path );
                $as->add_imm( 'x1', 16 );
                $as->load_reg_mem_byte( 'x0', $mode, 16 );
                $as->cmp_reg_imm( 'x0', ord('r') );
                $as->jcc( $driver->cc('ne'), $l_write );
                $as->mov_imm( 'x0', -100 );    # AT_FDCWD
                $as->mov_imm( 'x2',  0 );      # O_RDONLY
                $as->mov_imm( 'x3',  0 );
                $as->jmp($l_call);
                $as->mark_label($l_write);
                $as->mov_imm( 'x0', -100 );     # AT_FDCWD
                $as->mov_imm( 'x2', 0x241 );    # O_WRONLY | O_CREAT | O_TRUNC
                $as->mov_imm( 'x3', 0644 );
                $as->mark_label($l_call);
                $as->mov_imm( 'x8', 56 );       # sys_openat
                $as->syscall();
                $as->mov_reg( $reg_map->{ $inst->{dest} }, 'x0' );
            }
        }
        elsif ( $op eq 'intrinsic_get_size' ) {
            if ( $arch eq 'x64' ) {
                $as->mov_reg( 'rdi', $reg_map->{ $inst->{args}[0] } );
                $as->sub_imm( 'rsp', 144 );     # Space for struct stat
                $as->mov_reg( 'rsi', 'rsp' );
                $as->mov_imm( 'rax', 5 );       # sys_fstat
                $as->syscall();
                $as->load_reg_mem( $reg_map->{ $inst->{dest} }, 'rsp', 48 );    # st_size is at offset 48
                $as->add_imm( 'rsp', 144 );
            }
            else {
                $as->mov_reg( 'x0', $reg_map->{ $inst->{args}[0] } );
                $as->sub_imm( 'sp', 144 );
                $as->mov_reg( 'x1', 'sp' );
                $as->mov_imm( 'x8', 80 );                                       # sys_fstat
                $as->syscall();
                $as->load_reg_mem( $reg_map->{ $inst->{dest} }, 'sp', 48 );
                $as->add_imm( 'sp', 144 );
            }
        }
        elsif ( $op eq 'intrinsic_read' ) {
            if ( $arch eq 'x64' ) {
                $as->mov_reg( 'rdi', $reg_map->{ $inst->{args}[0] } );
                $as->mov_reg( 'rsi', $reg_map->{ $inst->{args}[1] } );
                $as->mov_reg( 'rdx', $reg_map->{ $inst->{args}[2] } );
                $as->mov_imm( 'rax', 0 );                                       # sys_read
                $as->syscall();
            }
            else {
                $as->mov_reg( 'x0', $reg_map->{ $inst->{args}[0] } );
                $as->mov_reg( 'x1', $reg_map->{ $inst->{args}[1] } );
                $as->mov_reg( 'x2', $reg_map->{ $inst->{args}[2] } );
                $as->mov_imm( 'x8', 63 );                                       # sys_read
                $as->syscall();
            }
        }
        elsif ( $op eq 'intrinsic_write' ) {
            if ( $arch eq 'x64' ) {
                $as->mov_reg( 'rdi', $reg_map->{ $inst->{args}[0] } );
                $as->mov_reg( 'rsi', $reg_map->{ $inst->{args}[1] } );
                $as->mov_reg( 'rdx', $reg_map->{ $inst->{args}[2] } );
                $as->mov_imm( 'rax', 1 );                                       # sys_write
                $as->syscall();
            }
            else {
                $as->mov_reg( 'x0', $reg_map->{ $inst->{args}[0] } );
                $as->mov_reg( 'x1', $reg_map->{ $inst->{args}[1] } );
                $as->mov_reg( 'x2', $reg_map->{ $inst->{args}[2] } );
                $as->mov_imm( 'x8', 64 );                                       # sys_write
                $as->syscall();
            }
        }
        elsif ( $op eq 'intrinsic_close' ) {
            if ( $arch eq 'x64' ) {
                $as->mov_reg( 'rdi', $reg_map->{ $inst->{args}[0] } );
                $as->mov_imm( 'rax', 3 );                                       # sys_close
                $as->syscall();
            }
            else {
                $as->mov_reg( 'x0', $reg_map->{ $inst->{args}[0] } );
                $as->mov_imm( 'x8', 57 );                                       # sys_close
                $as->syscall();
            }
        }
        elsif ( $op eq 'intrinsic_sleep' ) {
            my $val = $v->( $inst->{args}[0] );

            # 1. Untag value into RAX
            $as->mov_reg( 'rax', $val );
            $as->shr_imm( 'rax', 1 );

            # 2. Build struct timespec { long tv_sec, long tv_nsec } on stack
            # Use the 32-byte shadow-like space we have or just push
            $as->mov_imm( 'r11', 0 );    # 0 nanoseconds
            $as->push_reg('r11');        # tv_nsec
            $as->push_reg('rax');        # tv_sec

            # 3. nanosleep(struct timespec *req, struct timespec *rem)
            $as->mov_reg( 'rdi', 'rsp' );    # Pointer to our struct
            $as->mov_imm( 'rsi', 0 );        # rem = NULL
            $as->mov_imm( 'rax', 35 );       # sys_nanosleep
            $as->syscall();

            # 4. Clean up stack
            $as->add_imm( 'rsp', 16 );
        }
        elsif ( $op eq 'intrinsic_exit' ) {
            if ( $driver->coverage && $driver->coverage_table_size > 0 ) {
                if ( $arch eq 'x64' ) {
                    $as->mov_imm( 'rax', 1 );
                    $as->mov_imm( 'rdi', 2 );
                    $as->lea_rva( 'rsi', "DATA:" . $driver->coverage_table_offset );
                    $as->mov_imm( 'rdx', $driver->coverage_table_size );
                    $as->syscall();
                }
                else {
                    $as->mov_imm( 'x8', 64 );
                    $as->mov_imm( 'x0', 2 );
                    $as->lea_rva( 'x1', "DATA:" . $driver->coverage_table_offset );
                    $as->mov_imm( 'x2', $driver->coverage_table_size );
                    $as->syscall(1);
                }
            }
            my $val = $v->( $inst->{args}[0] );
            if ( $arch eq 'x64' ) {
                $as->mov_imm( 'rax', 60 );
                if ( $inst->{args}[0] =~ /^%/ ) {
                    $as->mov_reg( 'rdi', $val );
                    $as->shr_imm( 'rdi', 1 );
                }
                else {
                    my $untagged = ( defined $val && $val =~ /^\d+$/ ) ? ( $val >> 1 ) : ( $val // 0 );
                    $as->mov_imm( 'rdi', $untagged );
                }
            }
            else {
                $as->mov_imm( 'x8', 93 );
                if ( $inst->{args}[0] =~ /^%/ ) {
                    $as->mov_reg( 'x0', $val );
                    $as->lsr_reg_imm( 'x0', 'x0', 1 );
                }
                else {
                    my $untagged = ( defined $val && $val =~ /^\d+$/ ) ? ( $val >> 1 ) : ( $val // 0 );
                    $as->mov_imm( 'x0', $untagged );
                }
            }
            $as->syscall();
        }
        elsif ( $op eq 'intrinsic_emit_runtime' ) {
            $as->mark_label('M_fiber_switch');
            my $regs = $driver->preserved_regs();
            for my $r (@$regs) { $as->push_reg($r); }
            if ( $arch eq 'x64' ) {
                $as->mov_reg( 'rax', 'rsi' );
                $as->mov_reg( 'r10', 'rdi' );
                $as->load_reg_mem( 'r11', 'r14', $driver->iso_offset('current_fcb') );
                $as->store_mem_disp_reg( 'r11', $driver->fcb_offset('sp'),          'rsp' );
                $as->store_mem_disp_reg( 'r10', $driver->fcb_offset('caller'),      'r11' );
                $as->store_mem_disp_reg( 'r14', $driver->iso_offset('current_fcb'), 'r10' );
                $as->load_reg_mem( 'rsp', 'r10', $driver->fcb_offset('sp') );
            }
            else {
                # ARM64: x0=dest_fcb, x1=value
                $as->mov_reg( 'x16', 'x0' );                                              # x16 = dest_fcb
                $as->ldur_reg_mem( 'x17', 'x28', $driver->iso_offset('current_fcb') );    # x17 = current_fcb
                $as->mov_reg( 'x15', 'sp' );
                $as->stur_mem_disp_reg( 'x17', $driver->fcb_offset('sp'),          'x15' );
                $as->stur_mem_disp_reg( 'x16', $driver->fcb_offset('caller'),      'x17' );
                $as->stur_mem_disp_reg( 'x28', $driver->iso_offset('current_fcb'), 'x16' );
                $as->ldur_reg_mem( 'x15', 'x16', $driver->fcb_offset('sp') );
                $as->mov_reg( 'sp', 'x15' );
                $as->mov_reg( 'x0', 'x1' );                                               # value to return
            }
            for my $r ( reverse @$regs ) { $as->pop_reg($r); }
            if   ( $arch eq 'x64' ) { $as->append_code( pack( 'C',  0xC3 ) ); }
            else                    { $as->append_code( pack( 'L<', 0xD65F03C0 ) ); }     # ret
        }
    }
}
1;
__END__

=pod

=head1 NAME

Brocken::Platform::Linux - Linux platform support

=head1 SYNOPSIS

    my $platform = Brocken::Platform::Linux->new( os => 'linux' );
    my $name = $platform->format_name; # 'ELF'

=head1 DESCRIPTION

Implements the L<Brocken::Platform> interface for Linux (x64 and ARM64). Handles the ELF binary format and translates
intrinsics into direct Linux system calls (mmap, write, open, fstat, etc.).

=head1 METHODS

=head2 format_name

Returns C<'ELF'>.

=head2 shadow_space

Returns C<0>, as the System V ABI does not require shadow space.

=head2 emit_intrinsic($target, $as, $inst, $reg_map, $driver)

Emits machine code for intrinsics using architecture-specific system call numbers and registers.

=cut
