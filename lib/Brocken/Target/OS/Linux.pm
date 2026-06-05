use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';

class Brocken::Target::OS::Linux : isa(Brocken::Target::OS) {
    method format_name() {'ELF'}

    method emit_intrinsic( $target, $as, $inst, $reg_map, $driver ) {
        my $op        = $inst->{op};
        my $v         = sub { $target->val( $reg_map, shift ) };
        my $arch      = $driver->arch;
        my $os        = $driver->os;
        my $SYS_write = ( $os eq 'linux' || $arch eq 'riscv64' ) ? ( ( $arch eq 'x64' ) ? 1  : 64 ) : 4;
        my $SYS_exit  = ( $os eq 'linux' || $arch eq 'riscv64' ) ? ( ( $arch eq 'x64' ) ? 60 : 93 ) : 1;
        my $SYS_open  = ( $os eq 'linux' || $arch eq 'riscv64' ) ? ( ( $arch eq 'x64' ) ? 2  : 56 ) : 5;
        my $SYS_close = ( $os eq 'linux' || $arch eq 'riscv64' ) ? ( ( $arch eq 'x64' ) ? 3  : 57 ) : 6;
        my $SYS_read  = ( $os eq 'linux' || $arch eq 'riscv64' ) ? ( ( $arch eq 'x64' ) ? 0  : 63 ) : 3;
        my $SYS_mmap  = ( $os eq 'linux' || $arch eq 'riscv64' ) ? ( ( $arch eq 'x64' ) ? 9  : 222 ) :
            ( ( $os eq 'freebsd' || $os eq 'dragonfly' ) ? 477 : 197 );
        my $MAP_FLAGS = ( $os eq 'linux' ) ? 0x22 : 0x1002;

        if ( $op eq 'intrinsic_alloc' ) {
            my $d = $reg_map->{ $inst->{dest} };
            if ( $arch eq 'x64' ) {
                $as->mov_imm( 'rax', $SYS_mmap );
                $as->mov_imm( 'rdi', 0 );
                if ( $inst->{args}[0] =~ /^%/ ) { $as->mov_reg( 'rsi', $reg_map->{ $inst->{args}[0] } ); }
                else                            { $as->mov_imm( 'rsi', $v->( $inst->{args}[0] ) ); }
                $as->mov_imm( 'rdx', 3 );
                $as->mov_imm( 'r10', $MAP_FLAGS );
                $as->mov_imm( 'r8',  -1 );
                $as->mov_imm( 'r9',   0 );
                $as->syscall();
                $as->mov_reg( $d, 'rax' );
            }
            elsif ( $arch eq 'arm64' ) {
                $as->mov_imm( 'x8', $SYS_mmap );
                $as->mov_imm( 'x0', 0 );
                if ( $inst->{args}[0] =~ /^%/ ) { $as->mov_reg( 'x1', $reg_map->{ $inst->{args}[0] } ); }
                else                            { $as->mov_imm( 'x1', $v->( $inst->{args}[0] ) ); }
                $as->mov_imm( 'x2', 3 );
                $as->mov_imm( 'x3', $MAP_FLAGS );
                $as->mov_imm( 'x4', -1 );
                $as->mov_imm( 'x5',  0 );
                $as->syscall();
                $as->mov_reg( $d, 'x0' );
            }
            else {
                $as->mov_imm( 'a7', $SYS_mmap );
                $as->mov_imm( 'a0', 0 );
                if ( $inst->{args}[0] =~ /^%/ ) { $as->mov_reg( 'a1', $reg_map->{ $inst->{args}[0] } ); }
                else                            { $as->mov_imm( 'a1', $v->( $inst->{args}[0] ) ); }
                $as->mov_imm( 'a2', 3 );
                $as->mov_imm( 'a3', $MAP_FLAGS );
                $as->mov_imm( 'a4', -1 );
                $as->mov_imm( 'a5',  0 );
                $as->syscall();
                $as->mov_reg( $d, 'a0' );
            }
        }
        elsif ( $op eq 'intrinsic_align_entry_stack' ) {
            $as->sub_imm( 'rsp', 8 ) if $arch eq 'x64';
        }
        elsif ( $op eq 'intrinsic_load_library' ) {
            my $d = $reg_map->{ $inst->{dest} };
            if ( $arch eq 'x64' ) {
                $as->mov_reg( 'rdi', $reg_map->{ $inst->{args}[0] } );
                $as->add_imm( 'rdi', 16 );
                $as->mov_imm( 'rsi', 2 );
                $as->call_rva( $driver->import_rva('dlopen'), $driver->text_rva );
                $as->mov_reg( $d, 'rax' );
            }
            elsif ( $arch eq 'arm64' ) {
                $as->mov_reg( 'x0', $reg_map->{ $inst->{args}[0] } );
                $as->add_imm( 'x0', 16 );
                $as->mov_imm( 'x1', 2 );
                $as->call_rva( $driver->import_rva('dlopen'), $driver->text_rva );
                $as->mov_reg( $d, 'x0' );
            }
            else {
                $as->mov_reg( 'a0', $reg_map->{ $inst->{args}[0] } );
                $as->add_imm( 'a0', 16 );
                $as->mov_imm( 'a1', 2 );
                $as->call_rva( $driver->import_rva('dlopen'), $driver->text_rva );
                $as->mov_reg( $d, 'a0' );
            }
        }
        elsif ( $op eq 'intrinsic_get_proc_address' ) {
            my $d = $reg_map->{ $inst->{dest} };
            if ( $arch eq 'x64' ) {
                $as->mov_reg( 'rdi', $reg_map->{ $inst->{args}[0] } );
                $as->mov_reg( 'rsi', $reg_map->{ $inst->{args}[1] } );
                $as->add_imm( 'rsi', 16 );
                $as->call_rva( $driver->import_rva('dlsym'), $driver->text_rva );
                $as->mov_reg( $d, 'rax' );
            }
            elsif ( $arch eq 'arm64' ) {
                $as->mov_reg( 'x0', $reg_map->{ $inst->{args}[0] } );
                $as->mov_reg( 'x1', $reg_map->{ $inst->{args}[1] } );
                $as->add_imm( 'x1', 16 );
                $as->call_rva( $driver->import_rva('dlsym'), $driver->text_rva );
                $as->mov_reg( $d, 'x0' );
            }
            else {
                $as->mov_reg( 'a0', $reg_map->{ $inst->{args}[0] } );
                $as->mov_reg( 'a1', $reg_map->{ $inst->{args}[1] } );
                $as->add_imm( 'a1', 16 );
                $as->call_rva( $driver->import_rva('dlsym'), $driver->text_rva );
                $as->mov_reg( $d, 'a0' );
            }
        }
        elsif ( $op eq 'intrinsic_get_pid' ) {
            my $d = $reg_map->{ $inst->{dest} };
            if ( $arch eq 'x64' ) {
                $as->mov_imm( 'rax', 39 );
                $as->syscall();
                $as->mov_reg( $d, 'rax' );
            }
            elsif ( $arch eq 'arm64' ) {
                $as->mov_imm( 'x8', 172 );
                $as->syscall(1);
                $as->mov_reg( $d, 'x0' );
            }
            else {
                $as->mov_imm( 'a7', 172 );
                $as->syscall();
                $as->mov_reg( $d, 'a0' );
            }
        }
        elsif ( $op eq 'intrinsic_get_system_filetime' ) {
            my $d = $reg_map->{ $inst->{dest} };
            if ( $arch eq 'x64' ) {
                $as->sub_imm( 'rsp', 16 );
                $as->mov_imm( 'rax', 228 );
                $as->mov_imm( 'rdi', 0 );
                $as->mov_reg( 'rsi', 'rsp' );
                $as->syscall();
                $as->load_reg_mem( 'rax', 'rsp', 0 );
                $as->add_imm( 'rsp', 16 );
                $as->mov_imm( 'r10', 10000000 );
                $as->mul_reg( 'rax', 'r10' );
                $as->mov_imm( 'r11', 116444736000000000 );
                $as->add_reg( 'rax', 'r11' );
                $as->mov_reg( $d, 'rax' );
            }
            elsif ( $arch eq 'arm64' ) {
                $as->sub_imm( 'sp', 16 );
                $as->mov_imm( 'x8', 113 );
                $as->mov_imm( 'x0', 0 );
                $as->lea_reg_disp( 'x1', 'sp', 0 );
                $as->syscall(1);
                $as->load_reg_mem( 'x0', 'sp', 0 );
                $as->add_imm( 'sp', 16 );
                $as->mov_imm( 'x16', 10000000 );
                $as->mul_reg( 'x0', 'x0', 'x16' );
                $as->mov_imm( 'x17', 116444736000000000 );
                $as->add_reg( 'x0', 'x0', 'x17' );
                $as->mov_reg( $d, 'x0' );
            }
            else {
                $as->sub_imm( 'sp', 16 );
                $as->mov_imm( 'a7', 113 );
                $as->mov_imm( 'a0', 0 );
                $as->mov_reg( 'a1', 'sp' );
                $as->syscall();
                $as->load_reg_mem( 'a0', 'sp', 0 );
                $as->add_imm( 'sp', 16 );
                $as->mov_imm( 't0', 10000000 );
                $as->mul_reg( 'a0', 'a0', 't0' );
                $as->mov_imm( 't1', 116444736000000000 );
                $as->add_reg( 'a0', 'a0', 't1' );
                $as->mov_reg( $d, 'a0' );
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
                $as->mov_imm( 'rax', 89 );
                $as->mov_reg( 'rdi', 'rsp' );
                $as->mov_reg( 'rsi', $buf );
                $as->mov_imm( 'rdx', 512 );
                $as->syscall();
                $as->add_imm( 'rsp', 16 );
                $as->mov_reg( $d, 'rax' );
            }
            elsif ( $arch eq 'arm64' ) {
                $as->sub_imm( 'sp', 16 );
                $as->mov_imm( 'x16', $val2 );
                $as->store_mem_disp_reg( 'sp', 8, 'x16' );
                $as->mov_imm( 'x16', $val1 );
                $as->store_mem_disp_reg( 'sp', 0, 'x16' );
                $as->mov_imm( 'x8',  78 );
                $as->mov_imm( 'x0', -100 );
                $as->lea_reg_disp( 'x1', 'sp', 0 );
                $as->mov_reg( 'x2', $buf );
                $as->mov_imm( 'x3', 512 );
                $as->syscall(1);
                $as->add_imm( 'sp', 16 );
                $as->mov_reg( $d, 'x0' );
            }
            else {
                $as->sub_imm( 'sp', 16 );
                $as->mov_imm( 't0', $val2 );
                $as->store_mem_disp_reg( 'sp', 8, 't0' );
                $as->mov_imm( 't0', $val1 );
                $as->store_mem_disp_reg( 'sp', 0, 't0' );
                $as->mov_imm( 'a7',  78 );
                $as->mov_imm( 'a0', -100 );
                $as->mov_reg( 'a1', 'sp' );
                $as->mov_reg( 'a2', $buf );
                $as->mov_imm( 'a3', 512 );
                $as->syscall();
                $as->add_imm( 'sp', 16 );
                $as->mov_reg( $d, 'a0' );
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
        elsif ( $op eq 'intrinsic_spawn_thread' ) {
            my $d = $reg_map->{ $inst->{dest} };
            if ( $arch eq 'x64' ) {
                $as->mov_reg( 'r10', 'rsp' );
                $as->and_imm( 'rsp', -16 );
                $as->push_reg('r10');
                $as->sub_imm( 'rsp', 8 );
                $as->mov_reg( 'rdi', 'rsp' );
                $as->mov_imm( 'rsi', 0 );
                $as->lea_rva( 'rdx', 'M_thread_entry', $driver->text_rva );
                $as->mov_reg( 'rcx', $reg_map->{ $inst->{args}[0] } );
                $as->call_rva( $driver->import_rva('pthread_create'), $driver->text_rva );
                $as->load_reg_mem( 'r10', 'rsp', 0 );
                $as->add_imm( 'rsp', 8 );
                $as->pop_reg('rsp');
                $as->mov_reg( $d, 'r10' );
            }
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
            elsif ( $arch eq 'arm64' ) {
                $as->mov_reg( 'x1', $p );
                $as->ldur_reg_mem( 'x2', 'x1', 0 );
                $as->mov_imm( 'x16', hex("FFFFFFFFFF") );
                $as->and_reg( 'x2', 'x2', 'x16' );
                $as->add_imm( 'x1', 16 );
                $as->mov_imm( 'x0', 1 );
                $as->mov_imm( 'x8', $SYS_write );
                $as->syscall();
            }
            else {
                $as->mov_reg( 'a1', $p );
                $as->load_reg_mem( 'a2', 'a1', 0 );
                $as->add_imm( 'a1', 16 );
                $as->mov_imm( 'a0', 1 );
                $as->mov_imm( 'a7', $SYS_write );
                $as->syscall();
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
            elsif ( $arch eq 'arm64' ) {
                $as->mov_reg( 'x1', $p );
                $as->ldur_reg_mem( 'x2', 'x1', 0 );
                $as->mov_imm( 'x16', hex("FFFFFFFFFF") );
                $as->and_reg( 'x2', 'x2', 'x16' );
                $as->add_imm( 'x1', 16 );
                $as->mov_imm( 'x0', 2 );
                $as->mov_imm( 'x8', $SYS_write );
                $as->syscall();
            }
            else {
                $as->mov_reg( 'a1', $p );
                $as->load_reg_mem( 'a2', 'a1', 0 );
                $as->add_imm( 'a1', 16 );
                $as->mov_imm( 'a0', 2 );
                $as->mov_imm( 'a7', $SYS_write );
                $as->syscall();
            }
        }
        elsif ( $op eq 'intrinsic_print_stderr_char' ) {
            my $char = $v->( $inst->{args}[0] );
            if ( $arch eq 'x64' ) {
                my $src = ( $inst->{args}[0] =~ /^%/ ) ? $reg_map->{ $inst->{args}[0] } : 'r11';
                $as->mov_imm( 'r11', $char ) if $inst->{args}[0] !~ /^%/;
                $as->sub_imm( 'rsp', 16 );
                $as->store_mem_disp_byte( 'rsp', 0, $src );
                $as->mov_imm( 'rax', $SYS_write );
                $as->mov_imm( 'rdi', 2 );
                $as->mov_reg( 'rsi', 'rsp' );
                $as->mov_imm( 'rdx', 1 );
                $as->syscall();
                $as->add_imm( 'rsp', 16 );
            }
            elsif ( $arch eq 'arm64' ) {
                my $src = ( $inst->{args}[0] =~ /^%/ ) ? $reg_map->{ $inst->{args}[0] } : 'x16';
                $as->mov_imm( 'x16', $char ) if $inst->{args}[0] !~ /^%/;
                $as->sub_imm( 'sp', 16 );
                $as->sturb_mem_disp_reg( 'sp', 0, $src );
                $as->mov_imm( 'x8', $SYS_write );
                $as->mov_imm( 'x0', 2 );
                $as->lea_reg_disp( 'x1', 'sp', 0 );
                $as->mov_imm( 'x2', 1 );
                $as->syscall();
                $as->add_imm( 'sp', 16 );
            }
            else {
                my $src = ( $inst->{args}[0] =~ /^%/ ) ? $reg_map->{ $inst->{args}[0] } : 't0';
                $as->mov_imm( 't0', $char ) if $inst->{args}[0] !~ /^%/;
                $as->sub_imm( 'sp', 16 );
                $as->store_mem_disp_byte( 'sp', 0, $src );
                $as->mov_imm( 'a7', $SYS_write );
                $as->mov_imm( 'a0', 2 );
                $as->mov_reg( 'a1', 'sp' );
                $as->mov_imm( 'a2', 1 );
                $as->syscall();
                $as->add_imm( 'sp', 16 );
            }
        }
        elsif ( $op eq 'intrinsic_print_char' ) {
            my $char = $v->( $inst->{args}[0] );
            if ( $arch eq 'x64' ) {
                my $src = ( $inst->{args}[0] =~ /^%/ ) ? $reg_map->{ $inst->{args}[0] } : 'r11';
                $as->mov_imm( 'r11', $char ) if $inst->{args}[0] !~ /^%/;
                $as->sub_imm( 'rsp', 16 );
                $as->store_mem_disp_byte( 'rsp', 0, $src );
                $as->mov_imm( 'rax', $SYS_write );
                $as->mov_imm( 'rdi', 1 );
                $as->mov_reg( 'rsi', 'rsp' );
                $as->mov_imm( 'rdx', 1 );
                $as->syscall();
                $as->add_imm( 'rsp', 16 );
            }
            elsif ( $arch eq 'arm64' ) {
                my $src = ( $inst->{args}[0] =~ /^%/ ) ? $reg_map->{ $inst->{args}[0] } : 'x16';
                $as->mov_imm( 'x16', $char ) if $inst->{args}[0] !~ /^%/;
                $as->sub_imm( 'sp', 16 );
                $as->sturb_mem_disp_reg( 'sp', 0, $src );
                $as->mov_imm( 'x8', $SYS_write );
                $as->mov_imm( 'x0', 1 );
                $as->lea_reg_disp( 'x1', 'sp', 0 );
                $as->mov_imm( 'x2', 1 );
                $as->syscall();
                $as->add_imm( 'sp', 16 );
            }
            else {
                my $src = ( $inst->{args}[0] =~ /^%/ ) ? $reg_map->{ $inst->{args}[0] } : 't0';
                $as->mov_imm( 't0', $char ) if $inst->{args}[0] !~ /^%/;
                $as->sub_imm( 'sp', 16 );
                $as->store_mem_disp_byte( 'sp', 0, $src );
                $as->mov_imm( 'a7', $SYS_write );
                $as->mov_imm( 'a0', 1 );
                $as->mov_reg( 'a1', 'sp' );
                $as->mov_imm( 'a2', 1 );
                $as->syscall();
                $as->add_imm( 'sp', 16 );
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
                $as->mov_imm( 'rsi', 0 );
                $as->mov_imm( 'rdx', 0 );
                $as->jmp($l_call);
                $as->mark_label($l_write);
                $as->mov_imm( 'rsi', 0x241 );
                $as->mov_imm( 'rdx', 0644 );
                $as->mark_label($l_call);
                $as->mov_imm( 'rax', $SYS_open );
                $as->syscall();
                $as->mov_reg( $reg_map->{ $inst->{dest} }, 'rax' );
            }
            elsif ( $arch eq 'arm64' ) {
                $as->mov_reg( 'x1', $path );
                $as->add_imm( 'x1', 16 );
                $as->load_reg_mem_byte( 'x0', $mode, 16 );
                $as->cmp_reg_imm( 'x0', ord('r') );
                $as->jcc( $driver->cc('ne'), $l_write );
                $as->mov_imm( 'x0', -100 );
                $as->mov_imm( 'x2',  0 );
                $as->mov_imm( 'x3',  0 );
                $as->jmp($l_call);
                $as->mark_label($l_write);
                $as->mov_imm( 'x0', -100 );
                $as->mov_imm( 'x2', 0x241 );
                $as->mov_imm( 'x3', 0644 );
                $as->mark_label($l_call);
                $as->mov_imm( 'x8', $SYS_open );
                $as->syscall();
                $as->mov_reg( $reg_map->{ $inst->{dest} }, 'x0' );
            }
            else {
                $as->mov_reg( 'a1', $path );
                $as->add_imm( 'a1', 16 );
                $as->load_reg_mem_byte( 'a0', $mode, 16 );
                $as->cmp_reg_imm( 'a0', ord('r') );
                $as->jcc( $driver->cc('ne'), $l_write );
                $as->mov_imm( 'a0', -100 );
                $as->mov_imm( 'a2',  0 );
                $as->mov_imm( 'a3',  0 );
                $as->jmp($l_call);
                $as->mark_label($l_write);
                $as->mov_imm( 'a0', -100 );
                $as->mov_imm( 'a2', 0x241 );
                $as->mov_imm( 'a3', 0644 );
                $as->mark_label($l_call);
                $as->mov_imm( 'a7', $SYS_open );
                $as->syscall();
                $as->mov_reg( $reg_map->{ $inst->{dest} }, 'a0' );
            }
        }
        elsif ( $op eq 'intrinsic_get_size' ) {
            if ( $arch eq 'x64' ) {
                $as->mov_reg( 'rdi', $reg_map->{ $inst->{args}[0] } );
                $as->sub_imm( 'rsp', 144 );
                $as->mov_reg( 'rsi', 'rsp' );
                $as->mov_imm( 'rax', 5 );
                $as->syscall();
                $as->load_reg_mem( $reg_map->{ $inst->{dest} }, 'rsp', 48 );
                $as->add_imm( 'rsp', 144 );
            }
            elsif ( $arch eq 'arm64' ) {
                $as->mov_reg( 'x0', $reg_map->{ $inst->{args}[0] } );
                $as->sub_imm( 'sp', 144 );
                $as->lea_reg_disp( 'x1', 'sp', 0 );
                $as->mov_imm( 'x8', 80 );
                $as->syscall();
                $as->load_reg_mem( $reg_map->{ $inst->{dest} }, 'sp', 48 );
                $as->add_imm( 'sp', 144 );
            }
            else {
                $as->mov_reg( 'a0', $reg_map->{ $inst->{args}[0] } );
                $as->sub_imm( 'sp', 144 );
                $as->mov_reg( 'a1', 'sp' );
                $as->mov_imm( 'a7', 80 );
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
                $as->mov_imm( 'rax', $SYS_read );
                $as->syscall();
            }
            elsif ( $arch eq 'arm64' ) {
                $as->mov_reg( 'x0', $reg_map->{ $inst->{args}[0] } );
                $as->mov_reg( 'x1', $reg_map->{ $inst->{args}[1] } );
                $as->mov_reg( 'x2', $reg_map->{ $inst->{args}[2] } );
                $as->mov_imm( 'x8', $SYS_read );
                $as->syscall();
            }
            else {
                $as->mov_reg( 'a0', $reg_map->{ $inst->{args}[0] } );
                $as->mov_reg( 'a1', $reg_map->{ $inst->{args}[1] } );
                $as->mov_reg( 'a2', $reg_map->{ $inst->{args}[2] } );
                $as->mov_imm( 'a7', $SYS_read );
                $as->syscall();
            }
        }
        elsif ( $op eq 'intrinsic_write' ) {
            if ( $arch eq 'x64' ) {
                $as->mov_reg( 'rdi', $reg_map->{ $inst->{args}[0] } );
                $as->mov_reg( 'rsi', $reg_map->{ $inst->{args}[1] } );
                $as->mov_reg( 'rdx', $reg_map->{ $inst->{args}[2] } );
                $as->mov_imm( 'rax', $SYS_write );
                $as->syscall();
            }
            elsif ( $arch eq 'arm64' ) {
                $as->mov_reg( 'x0', $reg_map->{ $inst->{args}[0] } );
                $as->mov_reg( 'x1', $reg_map->{ $inst->{args}[1] } );
                $as->mov_reg( 'x2', $reg_map->{ $inst->{args}[2] } );
                $as->mov_imm( 'x8', $SYS_write );
                $as->syscall();
            }
            else {
                $as->mov_reg( 'a0', $reg_map->{ $inst->{args}[0] } );
                $as->mov_reg( 'a1', $reg_map->{ $inst->{args}[1] } );
                $as->mov_reg( 'a2', $reg_map->{ $inst->{args}[2] } );
                $as->mov_imm( 'a7', $SYS_write );
                $as->syscall();
            }
        }
        elsif ( $op eq 'intrinsic_close' ) {
            if ( $arch eq 'x64' ) {
                $as->mov_reg( 'rdi', $reg_map->{ $inst->{args}[0] } );
                $as->mov_imm( 'rax', $SYS_close );
                $as->syscall();
            }
            elsif ( $arch eq 'arm64' ) {
                $as->mov_reg( 'x0', $reg_map->{ $inst->{args}[0] } );
                $as->mov_imm( 'x8', $SYS_close );
                $as->syscall();
            }
            else {
                $as->mov_reg( 'a0', $reg_map->{ $inst->{args}[0] } );
                $as->mov_imm( 'a7', $SYS_close );
                $as->syscall();
            }
        }
        elsif ( $op eq 'intrinsic_sleep' ) {
            my $val = $v->( $inst->{args}[0] );
            if ( $arch eq 'x64' ) {
                $as->mov_reg( 'rax', $val );
                $as->shr_imm( 'rax', 1 );
                $as->mov_imm( 'r11', 0 );
                $as->push_reg('r11');
                $as->push_reg('rax');
                $as->mov_reg( 'rdi', 'rsp' );
                $as->mov_imm( 'rsi', 0 );
                $as->mov_imm( 'rax', 35 );
                $as->syscall();
                $as->add_imm( 'rsp', 16 );
            }
            elsif ( $arch eq 'arm64' ) {
                $as->mov_reg( 'x0', $val );
                $as->lsr_reg_imm( 'x0', 'x0', 1 );
                $as->mov_imm( 'x1', 0 );
                $as->sub_imm( 'sp', 16 );
                $as->stur_mem_disp_reg( 'sp', 0, 'x0' );
                $as->stur_mem_disp_reg( 'sp', 8, 'x1' );
                $as->lea_reg_disp( 'x0', 'sp', 0 );
                $as->mov_imm( 'x1', 0 );
                $as->mov_imm( 'x8', 101 );
                $as->syscall();
                $as->add_imm( 'sp', 16 );
            }
            else {
                $as->mov_reg( 'a0', $val );
                $as->lsr_reg_imm( 'a0', 'a0', 1 );
                $as->mov_imm( 'a1', 0 );
                $as->push_reg('a1');
                $as->push_reg('a0');
                $as->mov_reg( 'a0', 'sp' );
                $as->mov_imm( 'a1', 0 );
                $as->mov_imm( 'a7', 101 );
                $as->syscall();
                $as->add_imm( 'sp', 16 );
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
                elsif ( $arch eq 'arm64' ) {
                    $as->mov_imm( 'x8', $SYS_write );
                    $as->mov_imm( 'x0', 2 );
                    $as->lea_rva( 'x1', "DATA:" . $driver->coverage_table_offset );
                    $as->mov_imm( 'x2', $driver->coverage_table_size );
                    $as->syscall();
                }
                else {
                    $as->mov_imm( 'a7', $SYS_write );
                    $as->mov_imm( 'a0', 2 );
                    $as->lea_rva( 'a1', "DATA:" . $driver->coverage_table_offset );
                    $as->mov_imm( 'a2', $driver->coverage_table_size );
                    $as->syscall();
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
            }
            elsif ( $arch eq 'arm64' ) {
                $as->mov_imm( 'x8', $SYS_exit );
                if ( $inst->{args}[0] =~ /^%/ ) {
                    $as->mov_reg( 'x0', $val );
                    $as->lsr_reg_imm( 'x0', 'x0', 1 );
                }
                else {
                    my $untagged = ( defined $val && $val =~ /^\d+$/ ) ? ( $val >> 1 ) : ( $val // 0 );
                    $as->mov_imm( 'x0', $untagged );
                }
            }
            else {
                $as->mov_imm( 'a7', $SYS_exit );
                if ( $inst->{args}[0] =~ /^%/ ) {
                    $as->mov_reg( 'a0', $val );
                    $as->lsr_reg_imm( 'a0', 'a0', 1 );
                }
                else {
                    my $untagged = ( defined $val && $val =~ /^\d+$/ ) ? ( $val >> 1 ) : ( $val // 0 );
                    $as->mov_imm( 'a0', $untagged );
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
            elsif ( $arch eq 'arm64' ) {
                $as->mov_reg( 'x16', 'x0' );
                $as->ldur_reg_mem( 'x17', 'x28', $driver->iso_offset('current_fcb') );
                $as->lea_reg_disp( 'x15', 'sp', 0 );
                $as->stur_mem_disp_reg( 'x17', $driver->fcb_offset('sp'),          'x15' );
                $as->stur_mem_disp_reg( 'x16', $driver->fcb_offset('caller'),      'x17' );
                $as->stur_mem_disp_reg( 'x28', $driver->iso_offset('current_fcb'), 'x16' );
                $as->ldur_reg_mem( 'x15', 'x16', $driver->fcb_offset('sp') );
                $as->lea_reg_disp( 'sp', 'x15', 0 );
                $as->mov_reg( 'x0', 'x1' );
            }
            else {
                $as->mov_reg( 't0', 'a0' );
                $as->load_reg_mem( 't1', 's11', $driver->iso_offset('current_fcb') );
                $as->mov_reg( 't2', 'sp' );
                $as->store_mem_disp_reg( 't1',  $driver->fcb_offset('sp'),          't2' );
                $as->store_mem_disp_reg( 't0',  $driver->fcb_offset('caller'),      't1' );
                $as->store_mem_disp_reg( 's11', $driver->iso_offset('current_fcb'), 't0' );
                $as->load_reg_mem( 't2', 't0', $driver->fcb_offset('sp') );
                $as->mov_reg( 'sp', 't2' );
                $as->mov_reg( 'a0', 'a1' );
            }
            for my $r ( reverse @$regs ) { $as->pop_reg($r); }
            if    ( $arch eq 'x64' )   { $as->append_code( pack( 'C',  0xC3 ) ); }
            elsif ( $arch eq 'arm64' ) { $as->append_code( pack( 'L<', 0xD65F03C0 ) ); }
            else                       { $as->append_code( pack( 'L<', 0x00008067 ) ); }
        }
    }
}
1;
