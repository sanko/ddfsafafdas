use v5.40;
use feature 'class';
no warnings 'experimental::class';

class Brocken::Platform::Darwin : isa(Brocken::Platform) {
    method format_name() {'MachO'}

    method emit_intrinsic( $target, $as, $inst, $reg_map, $driver ) {
        my $op        = $inst->{op};
        my $v         = sub { $target->val( $reg_map, shift ) };
        my $arch      = $driver->arch;
        my $SYS_mmap  = 0x2000000 + 197;
        my $SYS_write = 0x2000000 + 4;
        my $SYS_exit  = 0x2000000 + 1;
        if ( $op eq 'intrinsic_alloc' ) {
            my $d = $reg_map->{ $inst->{dest} };
            if ( $arch eq 'x64' ) {
                $as->mov_imm( 'rax', $SYS_mmap );
                $as->mov_imm( 'rdi', 0 );
                if ( $inst->{args}[0] =~ /^%/ ) { $as->mov_reg( 'rsi', $reg_map->{ $inst->{args}[0] } ); }
                else                            { $as->mov_imm( 'rsi', $v->( $inst->{args}[0] ) ); }
                $as->mov_imm( 'rdx', 3 );         # PROT_READ | PROT_WRITE
                $as->mov_imm( 'r10', 0x1002 );    # MAP_PRIVATE | MAP_ANON (macOS uses 0x1000 for ANON)
                $as->mov_imm( 'r8',  -1 );
                $as->mov_imm( 'r9',  0 );
                $as->syscall();
                $as->mov_reg( $d, 'rax' );
            }
            else {
                # ARM64
                $as->mov_imm( 'x16', $SYS_mmap );
                $as->mov_imm( 'x0',  0 );           # addr
                if ( $inst->{args}[0] =~ /^%/ ) { $as->mov_reg( 'x1', $reg_map->{ $inst->{args}[0] } ); }
                else                            { $as->mov_imm( 'x1', $v->( $inst->{args}[0] ) ); }
                $as->mov_imm( 'x2', 3 );            # prot
                $as->mov_imm( 'x3', 0x1002 );       # flags
                $as->mov_imm( 'x4', -1 );           # fd
                $as->mov_imm( 'x5', 0 );            # off
                $as->syscall(1);                    # svc 0x80
                $as->mov_reg( $d, 'x0' );
            }
        }
        elsif ( $op eq 'intrinsic_get_pid' ) {
            my $d = $reg_map->{ $inst->{dest} };
            if ( $arch eq 'x64' ) {
                $as->mov_imm( 'rax', 0x2000014 );    # sys_getpid
                $as->syscall();
                $as->mov_reg( $d, 'rax' );
            }
            else {
                # ARM64
                $as->mov_imm( 'x16', 0x2000014 );    # sys_getpid
                $as->syscall(1);
                $as->mov_reg( $d, 'x0' );
            }
        }
        elsif ( $op eq 'intrinsic_get_system_filetime' ) {
            my $d = $reg_map->{ $inst->{dest} };
            if ( $arch eq 'x64' ) {
                $as->sub_imm( 'rsp', 16 );           # space for struct timeval
                $as->mov_reg( 'rdi', 'rsp' );
                $as->mov_imm( 'rsi', 0 );
                $as->mov_imm( 'rax', 0x2000074 );    # sys_gettimeofday
                $as->syscall();
                $as->load_reg_mem( 'rax', 'rsp', 0 );    # rax = tv_sec
                $as->load_reg_mem( 'rcx', 'rsp', 8 );    # rcx = tv_usec
                $as->add_imm( 'rsp', 16 );

                # Scale to FILETIME: (tv_sec * 10000000) + (tv_usec * 10) + 116444736000000000
                $as->mov_imm( 'r10', 10000000 );
                $as->mul_reg( 'rax', 'r10' );
                $as->mov_imm( 'r10', 10 );
                $as->mul_reg( 'rcx', 'r10' );
                $as->add_reg( 'rax', 'rcx' );
                $as->mov_imm( 'r11', 116444736000000000 );
                $as->add_reg( 'rax', 'r11' );
                $as->mov_reg( $d, 'rax' );
            }
            else {
                # ARM64
                $as->sub_imm( 'sp', 16 );            # space for struct timeval
                $as->mov_reg( 'x0', 'sp' );
                $as->mov_imm( 'x1',  0 );
                $as->mov_imm( 'x16', 0x2000074 );    # sys_gettimeofday
                $as->syscall(1);
                $as->load_reg_mem( 'x0', 'sp', 0 );    # x0 = tv_sec
                $as->load_reg_mem( 'x1', 'sp', 8 );    # x1 = tv_usec
                $as->add_imm( 'sp', 16 );
                $as->mov_imm( 'x16', 10000000 );
                $as->mul_reg( 'x0', 'x0', 'x16' );
                $as->mov_imm( 'x16', 10 );
                $as->mul_reg( 'x1', 'x1', 'x16' );
                $as->add_reg( 'x0', 'x0', 'x1' );
                $as->mov_imm( 'x17', 116444736000000000 );
                $as->add_reg( 'x0', 'x0', 'x17' );
                $as->mov_reg( $d, 'x0' );
            }
        }
        elsif ( $op eq 'intrinsic_get_module_filename' ) {
            my $d   = $reg_map->{ $inst->{dest} };
            my $buf = $reg_map->{ $inst->{args}[0] };
            if ( $arch eq 'x64' ) {

                # First get the PID
                $as->mov_imm( 'rax', 0x2000014 );    # sys_getpid
                $as->syscall();
                $as->mov_reg( 'rsi', 'rax' );        # pid into second arg rsi
                $as->mov_imm( 'rdi', 2 );            # PROC_INFO_CALL_PIDINFO
                $as->mov_imm( 'rdx', 11 );           # PROC_PIDPATHINFO
                $as->mov_imm( 'r10', 0 );            # arg
                $as->mov_reg( 'r8', $buf );          # buffer
                $as->mov_imm( 'r9',  512 );          # buffersize
                $as->mov_imm( 'rax', 0x2000150 );    # sys_proc_info
                $as->syscall();
                $as->mov_reg( $d, 'rax' );           # returns length or status
            }
            else {
                # ARM64
                # First get the PID
                $as->mov_imm( 'x16', 0x2000014 );    # sys_getpid
                $as->syscall(1);
                $as->mov_reg( 'x1', 'x0' );          # pid into second arg x1
                $as->mov_imm( 'x0', 2 );             # PROC_INFO_CALL_PIDINFO
                $as->mov_imm( 'x2', 11 );            # PROC_PIDPATHINFO
                $as->mov_imm( 'x3', 0 );             # arg
                $as->mov_reg( 'x4', $buf );          # buffer
                $as->mov_imm( 'x5',  512 );          # buffersize
                $as->mov_imm( 'x16', 0x2000150 );    # sys_proc_info
                $as->syscall(1);
                $as->mov_reg( $d, 'x0' );            # returns length or status
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
                $as->mov_imm( 'rax', $SYS_write );
                $as->syscall();
            }
            else {
                $as->mov_reg( 'x1', $p );
                $as->ldur_reg_mem( 'x2', 'x1', 0 );
                $as->add_imm( 'x1', 16 );
                $as->mov_imm( 'x0',  1 );
                $as->mov_imm( 'x16', $SYS_write );
                $as->syscall(1);
            }
        }
        elsif ( $op eq 'intrinsic_print_char' ) {
            my $char = $v->( $inst->{args}[0] );
            if ( $arch eq 'x64' ) {
                my $src = ( $inst->{args}[0] =~ /^%/ ) ? $reg_map->{ $inst->{args}[0] } : 'r11';
                $as->mov_imm( 'r11', $char ) if $inst->{args}[0] !~ /^%/;
                $as->store_mem_disp_byte( 'rsp', 48, $src );
                $as->mov_imm( 'rax', $SYS_write );
                $as->mov_imm( 'rdi', 1 );
                $as->append_code( pack( 'CCCC', 0x48, 0x8D, 0x74, 0x24 ) . pack( 'C', 48 ) );
                $as->mov_imm( 'rdx', 1 );
                $as->syscall();
            }
            else {
                my $src = ( $inst->{args}[0] =~ /^%/ ) ? $reg_map->{ $inst->{args}[0] } : 'x17';
                $as->mov_imm( 'x17', $char ) if $inst->{args}[0] !~ /^%/;
                $as->sturb_mem_disp_reg( 'sp', 48, $src );
                $as->mov_imm( 'x16', $SYS_write );
                $as->mov_imm( 'x0',  1 );
                $as->add_imm( 'x17', 0 );
                $as->mov_reg( 'x1', 'sp' );
                $as->add_imm( 'x1', 48 );
                $as->mov_imm( 'x2', 1 );
                $as->syscall(1);
            }
        }
        elsif ( $op eq 'intrinsic_print_stderr' ) {
            my $p = $reg_map->{ $inst->{args}[0] };
            if ( $arch eq 'x64' ) {
                $as->mov_reg( 'rsi', $p );
                $as->load_reg_mem( 'rdx', 'rsi', 0 );
                $as->add_imm( 'rsi', 16 );
                $as->mov_imm( 'rdi', 2 );
                $as->mov_imm( 'rax', $SYS_write );
                $as->syscall();
            }
            else {
                $as->mov_reg( 'x1', $p );
                $as->ldur_reg_mem( 'x2', 'x1', 0 );
                $as->add_imm( 'x1', 16 );
                $as->mov_imm( 'x0',  2 );
                $as->mov_imm( 'x16', $SYS_write );
                $as->syscall(1);
            }
        }
        elsif ( $op eq 'intrinsic_print_stderr_char' ) {
            my $char = $v->( $inst->{args}[0] );
            if ( $arch eq 'x64' ) {
                my $src = ( $inst->{args}[0] =~ /^%/ ) ? $reg_map->{ $inst->{args}[0] } : 'r11';
                $as->mov_imm( 'r11', $char ) if $inst->{args}[0] !~ /^%/;
                $as->store_mem_disp_byte( 'rsp', 48, $src );
                $as->mov_imm( 'rax', $SYS_write );
                $as->mov_imm( 'rdi', 2 );
                $as->append_code( pack( 'CCCC', 0x48, 0x8D, 0x74, 0x24 ) . pack( 'C', 48 ) );
                $as->mov_imm( 'rdx', 1 );
                $as->syscall();
            }
            else {
                my $src = ( $inst->{args}[0] =~ /^%/ ) ? $reg_map->{ $inst->{args}[0] } : 'x17';
                $as->mov_imm( 'x17', $char ) if $inst->{args}[0] !~ /^%/;
                $as->sturb_mem_disp_reg( 'sp', 48, $src );
                $as->mov_imm( 'x16', $SYS_write );
                $as->mov_imm( 'x0',  2 );
                $as->add_imm( 'x17', 0 );
                $as->mov_reg( 'x1', 'sp' );
                $as->add_imm( 'x1', 48 );
                $as->mov_imm( 'x2', 1 );
                $as->syscall(1);
            }
        }
        elsif ( $op eq 'intrinsic_open' ) {
            my ( $path, $mode ) = ( $reg_map->{ $inst->{args}[0] }, $reg_map->{ $inst->{args}[1] } );
            state $open_id = 0;
            my $l_write  = "intr_open_write_" . ++$open_id;
            my $l_call   = "intr_open_call_" . $open_id;
            my $SYS_open = 0x2000000 + 5;
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

                # O_WRONLY (1) | O_CREAT (0x0200) | O_TRUNC (0x0400) = 0x0601
                $as->mov_imm( 'rsi', 0x0601 );
                $as->mov_imm( 'rdx', 0644 );
                $as->mark_label($l_call);
                $as->mov_imm( 'rax', $SYS_open );
                $as->syscall();
                $as->mov_reg( $reg_map->{ $inst->{dest} }, 'rax' );
            }
            else {
                $as->mov_reg( 'x0', $path );
                $as->add_imm( 'x0', 16 );
                $as->load_reg_mem_byte( 'x1', $mode, 16 );
                $as->cmp_reg_imm( 'x1', ord('r') );
                $as->jcc( $driver->cc('ne'), $l_write );
                $as->mov_imm( 'x1', 0 );    # O_RDONLY
                $as->mov_imm( 'x2', 0 );
                $as->jmp($l_call);
                $as->mark_label($l_write);
                $as->mov_imm( 'x1', 0x0601 );    # O_WRONLY | O_CREAT | O_TRUNC
                $as->mov_imm( 'x2', 0644 );
                $as->mark_label($l_call);
                $as->mov_imm( 'x16', $SYS_open );
                $as->syscall(1);
                $as->mov_reg( $reg_map->{ $inst->{dest} }, 'x0' );
            }
        }
        elsif ( $op eq 'intrinsic_get_size' ) {
            my $SYS_fstat = 0x2000000 + 189;    # fstat64
            if ( $arch eq 'x64' ) {
                $as->mov_reg( 'rdi', $reg_map->{ $inst->{args}[0] } );
                $as->sub_imm( 'rsp', 144 );     # Space for struct stat64
                $as->mov_reg( 'rsi', 'rsp' );
                $as->mov_imm( 'rax', $SYS_fstat );
                $as->syscall();
                $as->load_reg_mem( $reg_map->{ $inst->{dest} }, 'rsp', 96 );    # st_size in macOS stat64 is at offset 96
                $as->add_imm( 'rsp', 144 );
            }
            else {
                $as->mov_reg( 'x0', $reg_map->{ $inst->{args}[0] } );
                $as->sub_imm( 'sp', 144 );
                $as->mov_reg( 'x1', 'sp' );
                $as->mov_imm( 'x16', $SYS_fstat );
                $as->syscall(1);
                $as->load_reg_mem( $reg_map->{ $inst->{dest} }, 'sp', 96 );
                $as->add_imm( 'sp', 144 );
            }
        }
        elsif ( $op eq 'intrinsic_read' ) {
            my $SYS_read = 0x2000000 + 3;
            if ( $arch eq 'x64' ) {
                $as->mov_reg( 'rdi', $reg_map->{ $inst->{args}[0] } );
                $as->mov_reg( 'rsi', $reg_map->{ $inst->{args}[1] } );
                $as->mov_reg( 'rdx', $reg_map->{ $inst->{args}[2] } );
                $as->mov_imm( 'rax', $SYS_read );
                $as->syscall();
            }
            else {
                $as->mov_reg( 'x0', $reg_map->{ $inst->{args}[0] } );
                $as->mov_reg( 'x1', $reg_map->{ $inst->{args}[1] } );
                $as->mov_reg( 'x2', $reg_map->{ $inst->{args}[2] } );
                $as->mov_imm( 'x16', $SYS_read );
                $as->syscall(1);
            }
        }
        elsif ( $op eq 'intrinsic_write' ) {
            my $SYS_write = 0x2000000 + 4;
            if ( $arch eq 'x64' ) {
                $as->mov_reg( 'rdi', $reg_map->{ $inst->{args}[0] } );
                $as->mov_reg( 'rsi', $reg_map->{ $inst->{args}[1] } );
                $as->mov_reg( 'rdx', $reg_map->{ $inst->{args}[2] } );
                $as->mov_imm( 'rax', $SYS_write );
                $as->syscall();
            }
            else {
                $as->mov_reg( 'x0', $reg_map->{ $inst->{args}[0] } );
                $as->mov_reg( 'x1', $reg_map->{ $inst->{args}[1] } );
                $as->mov_reg( 'x2', $reg_map->{ $inst->{args}[2] } );
                $as->mov_imm( 'x16', $SYS_write );
                $as->syscall(1);
            }
        }
        elsif ( $op eq 'intrinsic_close' ) {
            my $SYS_close = 0x2000000 + 6;
            if ( $arch eq 'x64' ) {
                $as->mov_reg( 'rdi', $reg_map->{ $inst->{args}[0] } );
                $as->mov_imm( 'rax', $SYS_close );
                $as->syscall();
            }
            else {
                $as->mov_reg( 'x0', $reg_map->{ $inst->{args}[0] } );
                $as->mov_imm( 'x16', $SYS_close );
                $as->syscall(1);
            }
        }
        elsif ( $op eq 'intrinsic_exit' ) {
            if ( $driver->coverage && $driver->coverage_table_size > 0 ) {
                if ( $arch eq 'x64' ) {
                    $as->mov_imm( 'rax', $SYS_write );
                    $as->mov_imm( 'rdi', 2 );
                    $as->lea_rva( 'rsi', "DATA:" . $driver->coverage_table_offset );
                    $as->mov_imm( 'rdx', $driver->coverage_table_size );
                    $as->syscall();
                }
                else {
                    $as->mov_imm( 'x16', $SYS_write );
                    $as->mov_imm( 'x0',  2 );
                    $as->lea_rva( 'x1', "DATA:" . $driver->coverage_table_offset );
                    $as->mov_imm( 'x2', $driver->coverage_table_size );
                    $as->syscall(1);
                }
            }
            my $val = $v->( $inst->{args}[0] );
            if ( $arch eq 'x64' ) {
                $as->mov_imm( 'rax', $SYS_exit );
                if ( $inst->{args}[0] =~ /^%/ ) {
                    $as->mov_reg( 'rdi', $val );
                    $as->shr_imm( 'rdi', 1 );
                }
                else {
                    my $untagged = ( defined $val && $val =~ /^\d+$/ ) ? ( $val >> 1 ) : ( $val // 0 );
                    $as->mov_imm( 'rdi', $untagged );
                }
                $as->syscall();
            }
            else {
                $as->mov_imm( 'x16', $SYS_exit );
                if ( $inst->{args}[0] =~ /^%/ ) {
                    $as->mov_reg( 'x0', $val );
                    $as->lsr_reg_imm( 'x0', 'x0', 1 );
                }
                else {
                    my $untagged = ( defined $val && $val =~ /^\d+$/ ) ? ( $val >> 1 ) : ( $val // 0 );
                    $as->mov_imm( 'x0', $untagged );
                }
                $as->syscall(1);
            }
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

Brocken::Platform::Darwin - macOS (Darwin) platform support

=head1 SYNOPSIS

    my $platform = Brocken::Platform::Darwin->new( os => 'macos' );
    my $name = $platform->format_name; # 'MachO'

=head1 DESCRIPTION

Implements the L<Brocken::Platform> interface for macOS (x64 and ARM64). Handles the Mach-O binary format and
translates intrinsics into Darwin system calls. Darwin system calls are typically prefixed with C<0x2000000> on x64.

=head1 METHODS

=head2 format_name

Returns C<'MachO'>.

=head2 shadow_space

Returns C<0>.

=head2 emit_intrinsic($target, $as, $inst, $reg_map, $driver)

Emits machine code for intrinsics using Darwin-specific system call numbers.

=cut
