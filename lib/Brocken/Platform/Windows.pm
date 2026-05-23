use v5.40;
use feature 'class';
no warnings 'experimental::class';

class Brocken::Platform::Windows : isa(Brocken::Platform) {
    method format_name()  {'PE'}
    method shadow_space() {32}

    method emit_intrinsic( $target, $as, $inst, $reg_map, $driver ) {
        my $op = $inst->{op};
        my $v  = sub { $target->val( $reg_map, shift ) };
        if ( $op eq 'intrinsic_alloc' ) {
            my $d = $reg_map->{ $inst->{dest} };
            $as->sub_imm( 'rsp', 32 );    # Allocate Shadow Space
            $as->mov_imm( 'rcx', 0 );
            if ( $inst->{args}[0] =~ /^%/ ) { $as->mov_reg( 'rdx', $reg_map->{ $inst->{args}[0] } ); }
            else                            { $as->mov_imm( 'rdx', $v->( $inst->{args}[0] ) ); }
            $as->mov_imm( 'r8', 0x3000 );
            $as->mov_imm( 'r9', 0x04 );
            $as->call_rva( $driver->import_rva('VirtualAlloc'), $driver->text_rva );
            $as->add_imm( 'rsp', 32 );    # Deallocate Shadow Space
            $as->mov_reg( $d, 'rax' );
        }
        elsif ( $op eq 'intrinsic_load_library' ) {
            my $d = $reg_map->{ $inst->{dest} };
            $as->sub_imm( 'rsp', 32 );    # Allocate Shadow Space
            $as->mov_reg( 'rcx', $reg_map->{ $inst->{args}[0] } );
            $as->add_imm( 'rcx', 16 );    # Skip the 16-byte Brocken String Header
            $as->call_rva( $driver->import_rva('LoadLibraryA'), $driver->text_rva );
            $as->add_imm( 'rsp', 32 );    # Deallocate Shadow Space
            $as->mov_reg( $d, 'rax' );
        }
        elsif ( $op eq 'intrinsic_get_proc_address' ) {
            my $d = $reg_map->{ $inst->{dest} };
            $as->sub_imm( 'rsp', 32 );                                # Allocate Shadow Space
            $as->mov_reg( 'rcx', $reg_map->{ $inst->{args}[0] } );    # DLL Handle
            $as->mov_reg( 'rdx', $reg_map->{ $inst->{args}[1] } );    # Func Name String
            $as->add_imm( 'rdx', 16 );                                # Skip the 16-byte Brocken String Header
            $as->call_rva( $driver->import_rva('GetProcAddress'), $driver->text_rva );
            $as->add_imm( 'rsp', 32 );                                # Deallocate Shadow Space
            $as->mov_reg( $d, 'rax' );
        }
        elsif ( $op eq 'intrinsic_get_env_block' ) {
            my $d = $reg_map->{ $inst->{dest} };
            $as->sub_imm( 'rsp', 32 );                                # Allocate Shadow Space
            $as->call_rva( $driver->import_rva('GetEnvironmentStringsA'), $driver->text_rva );
            $as->add_imm( 'rsp', 32 );                                # Deallocate Shadow Space
            $as->mov_reg( $d, 'rax' );
        }
        elsif ( $op eq 'intrinsic_free_env_block' ) {
            $as->sub_imm( 'rsp', 32 );                                # Allocate Shadow Space
            $as->mov_reg( 'rcx', $reg_map->{ $inst->{args}[0] } );
            $as->call_rva( $driver->import_rva('FreeEnvironmentStringsA'), $driver->text_rva );
            $as->add_imm( 'rsp', 32 );                                # Deallocate Shadow Space
        }
        elsif ( $op eq 'intrinsic_get_pid' ) {
            my $d = $reg_map->{ $inst->{dest} };
            $as->sub_imm( 'rsp', 32 );                                # Allocate Shadow Space
            $as->call_rva( $driver->import_rva('GetCurrentProcessId'), $driver->text_rva );
            $as->add_imm( 'rsp', 32 );                                # Deallocate Shadow Space
            $as->mov_reg( $d, 'rax' );
        }
        elsif ( $op eq 'intrinsic_get_system_filetime' ) {
            my $d = $reg_map->{ $inst->{dest} };
            $as->sub_imm( 'rsp', 32 );                                # Allocate Shadow Space
            $as->mov_reg( 'rcx', 'rsp' );                             # Point to the shadow space itself
            $as->call_rva( $driver->import_rva('GetSystemTimeAsFileTime'), $driver->text_rva );
            $as->load_reg_mem( $d, 'rsp', 0 );
            $as->add_imm( 'rsp', 32 );                                # Deallocate Shadow Space
        }
        elsif ( $op eq 'intrinsic_get_module_filename' ) {
            my $d = $reg_map->{ $inst->{dest} };
            $as->sub_imm( 'rsp', 32 );                                # Allocate Shadow Space
            $as->mov_imm( 'rcx', 0 );                                 # NULL = Current executable
            $as->mov_reg( 'rdx', $reg_map->{ $inst->{args}[0] } );    # buffer
            $as->mov_imm( 'r8', 512 );                                # buffer size
            $as->call_rva( $driver->import_rva('GetModuleFileNameA'), $driver->text_rva );
            $as->add_imm( 'rsp', 32 );                                # Deallocate Shadow Space
            $as->mov_reg( $d, 'rax' );                                # returns length of string
        }
        elsif ( $op eq 'intrinsic_get_cmd_line' ) {
            my $d = $reg_map->{ $inst->{dest} };
            $as->sub_imm( 'rsp', 32 );                                # Allocate Shadow Space
            $as->call_rva( $driver->import_rva('GetCommandLineA'), $driver->text_rva );
            $as->add_imm( 'rsp', 32 );                                # Deallocate Shadow Space
            $as->mov_reg( $d, 'rax' );
        }
        elsif ( $op eq 'intrinsic_get_stdout_handle' ) {
            my $d = $reg_map->{ $inst->{dest} };
            $as->sub_imm( 'rsp', 32 );                                # Allocate Shadow Space
            $as->mov_imm( 'rcx', -11 );                               # STD_OUTPUT_HANDLE
            $as->call_rva( $driver->import_rva('GetStdHandle'), $driver->text_rva );
            $as->add_imm( 'rsp', 32 );                                # Deallocate Shadow Space
            $as->mov_reg( $d, 'rax' );
        }
        elsif ( $op eq 'intrinsic_get_stderr_handle' ) {
            my $d = $reg_map->{ $inst->{dest} };
            $as->sub_imm( 'rsp', 32 );                                # Allocate Shadow Space
            $as->mov_imm( 'rcx', -12 );                               # STD_ERROR_HANDLE
            $as->call_rva( $driver->import_rva('GetStdHandle'), $driver->text_rva );
            $as->add_imm( 'rsp', 32 );                                # Deallocate Shadow Space
            $as->mov_reg( $d, 'rax' );
        }
        elsif ( $op eq 'intrinsic_get_stdin_handle' ) {
            my $d = $reg_map->{ $inst->{dest} };
            $as->sub_imm( 'rsp', 32 );                                # Allocate Shadow Space
            $as->mov_imm( 'rcx', -10 );                               # STD_INPUT_HANDLE
            $as->call_rva( $driver->import_rva('GetStdHandle'), $driver->text_rva );
            $as->add_imm( 'rsp', 32 );                                # Deallocate Shadow Space
            $as->mov_reg( $d, 'rax' );
        }
        elsif ( $op eq 'intrinsic_spawn_thread' ) {
            my $d = $reg_map->{ $inst->{dest} };
            $as->sub_imm( 'rsp', 48 ); # Allocate shadow + parameter space (6 arguments)
            $as->mov_imm( 'rcx', 0 );  # lpThreadAttributes = NULL
            $as->mov_imm( 'rdx', 0 );  # dwStackSize = 0 (Default)
            $as->lea_rva( 'r8', 'M_thread_entry', $driver->text_rva ); # lpStartAddress
            $as->mov_reg( 'r9', $reg_map->{ $inst->{args}[0] } ); # lpParameter (target sub ptr)
            $as->mov_imm( 'rax', 0 );
            $as->store_mem_disp_reg( 'rsp', 32, 'rax' ); # dwCreationFlags = 0
            $as->store_mem_disp_reg( 'rsp', 40, 'rax' ); # lpThreadId = NULL
            $as->call_rva( $driver->import_rva('CreateThread'), $driver->text_rva );
            $as->add_imm( 'rsp', 48 );
            $as->mov_reg( $d, 'rax' );
        }
        elsif ( $op eq 'intrinsic_print' || $op eq 'intrinsic_print_char' ) {
            my $is_char = ( $op eq 'intrinsic_print_char' );
            my $p       = $reg_map->{ $inst->{args}[0] };
            $as->sub_imm( 'rsp', 48 );                                # Allocate Shadow Space + 16 bytes for parameter passing/alignment
            if ($is_char) {
                my $src = ( $inst->{args}[0] =~ /^%/ ) ? $p : 'r11';
                $as->mov_imm( 'r11', $v->( $inst->{args}[0] ) ) if $inst->{args}[0] !~ /^%/;
                $as->store_mem_disp_byte( 'rsp', 40, $src );
            }
            $as->mov_imm( 'rcx', -11 );
            $as->call_rva( $driver->import_rva('GetStdHandle'), $driver->text_rva );
            $as->mov_reg( 'rcx', 'rax' );
            if ($is_char) { $as->lea_reg_disp( 'rdx', 'rsp', 40 ); $as->mov_imm( 'r8', 1 ); }
            else          { $as->mov_reg( 'rdx', $p ); $as->add_imm( 'rdx', 16 ); $as->load_reg_mem( 'r8', $p, 0 ); }
            $as->lea_reg_disp( 'r9', 'rsp', 44 );
            $as->mov_imm( 'rax', 0 );
            $as->store_mem_disp_reg( 'rsp', 32, 'rax' );
            $as->call_rva( $driver->import_rva('WriteFile'), $driver->text_rva );
            $as->add_imm( 'rsp', 48 );    # Deallocate Shadow Space
        }
        elsif ( $op eq 'intrinsic_print_stderr' ) {
            my $p = $reg_map->{ $inst->{args}[0] };
            $as->sub_imm( 'rsp', 48 );    # Allocate Shadow Space + 16 bytes for parameter passing/alignment
            $as->mov_imm( 'rcx', -12 );
            $as->call_rva( $driver->import_rva('GetStdHandle'), $driver->text_rva );
            $as->mov_reg( 'rcx', 'rax' );
            $as->mov_reg( 'rdx', $p );
            $as->add_imm( 'rdx', 16 );
            $as->load_reg_mem( 'r8', $p, 0 );
            $as->lea_reg_disp( 'r9', 'rsp', 44 );
            $as->mov_imm( 'rax', 0 );
            $as->store_mem_disp_reg( 'rsp', 32, 'rax' );
            $as->call_rva( $driver->import_rva('WriteFile'), $driver->text_rva );
            $as->add_imm( 'rsp', 48 );    # Deallocate Shadow Space
        }
        elsif ( $op eq 'intrinsic_print_stderr_char' ) {
            my $src = ( $inst->{args}[0] =~ /^%/ ) ? $reg_map->{ $inst->{args}[0] } : 'r11';
            $as->mov_imm( 'r11', $v->( $inst->{args}[0] ) ) if $inst->{args}[0] !~ /^%/;
            $as->sub_imm( 'rsp', 48 );    # Allocate Shadow Space + 16 bytes for parameter passing/alignment
            $as->store_mem_disp_byte( 'rsp', 40, $src );
            $as->mov_imm( 'rcx', -12 );
            $as->call_rva( $driver->import_rva('GetStdHandle'), $driver->text_rva );
            $as->mov_reg( 'rcx', 'rax' );
            $as->lea_reg_disp( 'rdx', 'rsp', 40 );
            $as->mov_imm( 'r8', 1 );
            $as->lea_reg_disp( 'r9', 'rsp', 44 );
            $as->mov_imm( 'rax', 0 );
            $as->store_mem_disp_reg( 'rsp', 32, 'rax' );
            $as->call_rva( $driver->import_rva('WriteFile'), $driver->text_rva );
            $as->add_imm( 'rsp', 48 );    # Deallocate Shadow Space
        }
        elsif ( $op eq 'intrinsic_open' ) {
            my ( $path, $mode ) = ( $reg_map->{ $inst->{args}[0] }, $reg_map->{ $inst->{args}[1] } );
            state $open_id = 0;
            my $l_write = "intr_open_write_" . ++$open_id;
            my $l_call  = "intr_open_call_" . $open_id;
            $as->sub_imm( 'rsp', 64 );    # Allocate Shadow Space + 32 bytes for parameters 5, 6, and 7
            $as->mov_reg( 'rcx', $path );
            $as->add_imm( 'rcx', 16 );    # Skip Brocken string header
            $as->load_reg_mem_byte( 'rax', $mode, 16 );
            $as->cmp_reg_imm( 'rax', ord('r') );
            $as->jcc( $driver->cc('ne'), $l_write );

            # Read Mode
            $as->mov_imm( 'rdx', 0x80000000 );    # GENERIC_READ
            $as->mov_imm( 'r8',  1 );             # FILE_SHARE_READ
            $as->mov_imm( 'r9',  0 );             # Security
            $as->mov_imm( 'rax', 3 );             # OPEN_EXISTING
            $as->store_mem_disp_reg( 'rsp', 32, 'rax' );
            $as->mov_imm( 'rax', 0x80 );          # NORMAL
            $as->store_mem_disp_reg( 'rsp', 40, 'rax' );
            $as->mov_imm( 'rax', 0 );
            $as->store_mem_disp_reg( 'rsp', 48, 'rax' );
            $as->jmp($l_call);
            $as->mark_label($l_write);

            # Write Mode
            $as->mov_imm( 'rdx', 0x40000000 );    # GENERIC_WRITE
            $as->mov_imm( 'r8',  0 );
            $as->mov_imm( 'r9',  0 );
            $as->mov_imm( 'rax', 2 );             # CREATE_ALWAYS
            $as->store_mem_disp_reg( 'rsp', 32, 'rax' );
            $as->mov_imm( 'rax', 0x80 );
            $as->store_mem_disp_reg( 'rsp', 40, 'rax' );
            $as->mov_imm( 'rax', 0 );
            $as->store_mem_disp_reg( 'rsp', 48, 'rax' );
            $as->mark_label($l_call);
            $as->call_rva( $driver->import_rva('CreateFileA'), $driver->text_rva );
            $as->add_imm( 'rsp', 64 );            # Deallocate Shadow Space
            $as->mov_reg( $reg_map->{ $inst->{dest} }, 'rax' );
        }
        elsif ( $op eq 'intrinsic_get_size' ) {
            $as->sub_imm( 'rsp', 48 );            # Allocate Shadow Space + 16 bytes for parameter passing/alignment
            $as->mov_reg( 'rcx', $reg_map->{ $inst->{args}[0] } );
            $as->lea_reg_disp( 'rdx', 'rsp', 32 );
            $as->call_rva( $driver->import_rva('GetFileSizeEx'), $driver->text_rva );
            $as->load_reg_mem( $reg_map->{ $inst->{dest} }, 'rsp', 32 );
            $as->add_imm( 'rsp', 48 );            # Deallocate Shadow Space
        }
        elsif ( $op eq 'intrinsic_read' ) {
            $as->sub_imm( 'rsp', 48 );            # Allocate Shadow Space + 16 bytes for parameter passing/alignment
            $as->mov_reg( 'rcx', $reg_map->{ $inst->{args}[0] } );
            $as->mov_reg( 'rdx', $reg_map->{ $inst->{args}[1] } );
            $as->mov_reg( 'r8',  $reg_map->{ $inst->{args}[2] } );
            $as->lea_reg_disp( 'r9', 'rsp', 40 );
            $as->mov_imm( 'rax', 0 );
            $as->store_mem_disp_reg( 'rsp', 32, 'rax' );
            $as->call_rva( $driver->import_rva('ReadFile'), $driver->text_rva );
            $as->add_imm( 'rsp', 48 );            # Deallocate Shadow Space
        }
        elsif ( $op eq 'intrinsic_write' ) {
            $as->sub_imm( 'rsp', 48 );            # Allocate Shadow Space + 16 bytes for parameter passing/alignment
            $as->mov_reg( 'rcx', $reg_map->{ $inst->{args}[0] } );
            $as->mov_reg( 'rdx', $reg_map->{ $inst->{args}[1] } );
            $as->mov_reg( 'r8',  $reg_map->{ $inst->{args}[2] } );
            $as->lea_reg_disp( 'r9', 'rsp', 40 );
            $as->mov_imm( 'rax', 0 );
            $as->store_mem_disp_reg( 'rsp', 32, 'rax' );
            $as->call_rva( $driver->import_rva('WriteFile'), $driver->text_rva );
            $as->add_imm( 'rsp', 48 );            # Deallocate Shadow Space
        }
        elsif ( $op eq 'intrinsic_close' ) {
            $as->sub_imm( 'rsp', 32 );            # Allocate Shadow Space
            $as->mov_reg( 'rcx', $reg_map->{ $inst->{args}[0] } );
            $as->call_rva( $driver->import_rva('CloseHandle'), $driver->text_rva );
            $as->add_imm( 'rsp', 32 );            # Deallocate Shadow Space
        }
        elsif ( $op eq 'intrinsic_create_wait_handle' ) {
            $as->sub_imm( 'rsp', 32 );            # Allocate Shadow Space
            $as->mov_imm( 'rcx', 0 );             # Attributes
            $as->mov_imm( 'rdx', 0 );             # Manual Reset = False
            $as->mov_imm( 'r8',  0 );             # Initial State = Non-signaled
            $as->mov_imm( 'r9',  0 );             # Name
            $as->call_rva( $driver->import_rva('CreateEventA'), $driver->text_rva );
            $as->add_imm( 'rsp', 32 );            # Deallocate Shadow Space
            $as->mov_reg( $reg_map->{ $inst->{dest} }, 'rax' );
        }
        elsif ( $op eq 'intrinsic_sleep' ) {
            my $val = $v->( $inst->{args}[0] );

            # rcx = current_fcb->wait_handle
            $as->load_reg_mem( 'r11', 'r14', $driver->iso_offset('current_fcb') );
            $as->load_reg_mem( 'rcx', 'r11', $driver->fcb_offset('wait_handle') );

            # rdx = timeout in ms
            $as->mov_reg( 'rdx', ( $inst->{args}[0] =~ /^%/ ) ? $reg_map->{ $inst->{args}[0] } : 'r11' );
            $as->mov_imm( 'r11', $val ) if $inst->{args}[0] !~ /^%/;
            $as->shr_imm( 'rdx', 1 );    # Untag
            $as->mov_imm( 'rax', 1000 );
            $as->mul_reg( 'rdx', 'rax' );

            # WaitForSingleObject(handle, timeout)
            $as->sub_imm( 'rsp', 32 );    # Allocate Shadow Space
            $as->call_rva( $driver->import_rva('WaitForSingleObject'), $driver->text_rva );
            $as->add_imm( 'rsp', 32 );    # Deallocate Shadow Space
        }
        elsif ( $op eq 'intrinsic_interrupt' ) {
            $as->sub_imm( 'rsp', 32 );    # Allocate Shadow Space

            # rcx = target_fiber->wait_handle
            $as->load_reg_mem( 'rcx', $reg_map->{ $inst->{args}[0] }, $driver->fcb_offset('wait_handle') );
            $as->call_rva( $driver->import_rva('SetEvent'), $driver->text_rva );
            $as->add_imm( 'rsp', 32 );    # Deallocate Shadow Space
        }
        elsif ( $op eq 'intrinsic_exit' ) {
            if ( $driver->coverage && $driver->coverage_table_size > 0 ) {
                $self->_emit_coverage_dump_x64( $as, $driver );
            }
            my $val = $v->( $inst->{args}[0] );
            $as->sub_imm( 'rsp', 32 );    # Allocate Shadow Space
            if ( $inst->{args}[0] =~ /^%/ ) {
                $as->mov_reg( 'rcx', $val );
                $as->shr_imm( 'rcx', 1 );    # Untag: (N * 2 + 1) >> 1 == N
            }
            else {
                my $untagged = ( defined $val && $val =~ /^\d+$/ ) ? ( $val >> 1 ) : ( $val // 0 );
                $as->mov_imm( 'rcx', $untagged );
            }
            $as->call_rva( $driver->import_rva('ExitProcess'), $driver->text_rva );

            # ExitProcess never returns, so we don't need to clean up RSP here
        }
        elsif ( $op eq 'intrinsic_setup_env' ) {
            $as->sub_imm( 'rsp', 32 );    # Allocate Shadow Space
            $as->mov_imm( 'rcx', 65001 );
            $as->call_rva( $driver->import_rva('SetConsoleOutputCP'), $driver->text_rva );
            $as->add_imm( 'rsp', 32 );    # Deallocate Shadow Space
        }
        elsif ( $op eq 'intrinsic_setup_fault_handler' ) {
            $as->sub_imm( 'rsp', 32 );    # Allocate Shadow Space
            $as->mov_imm( 'rcx', 1 );
            $as->lea_rva( 'rdx', 'M_veh_handler', $driver->text_rva );
            $as->call_rva( $driver->import_rva('AddVectoredExceptionHandler'), $driver->text_rva );
            $as->add_imm( 'rsp', 32 );    # Deallocate Shadow Space
        }
        elsif ( $op eq 'intrinsic_emit_runtime' ) {
            $as->mark_label('M_veh_handler');
            $as->load_reg_mem( 'rax', 'rcx', 0 );
            $as->append_code( pack( 'CCC', 0x44, 0x8B, 0x18 ) );
            $as->cmp_reg_imm_32( 'r11', 0xC0000005 );
            $as->jcc( 5, 'veh_not_handled' );
            $as->load_reg_mem( 'r8', 'rax', 40 );
            $as->mov_imm( 'r11', -4096 );
            $as->append_code( pack( 'CCC', 0x4D, 0x21, 0xD8 ) );
            $as->sub_imm( 'rsp', 40 );
            $as->mov_reg( 'rcx', 'r8' );
            $as->mov_imm( 'rdx', 4096 );
            $as->mov_imm( 'r8',  0x1000 );
            $as->mov_imm( 'r9',  4 );
            $as->call_rva( $driver->import_rva('VirtualAlloc'), $driver->text_rva );
            $as->add_imm( 'rsp', 40 );
            $as->cmp_reg_imm( 'rax', 0 );
            $as->jcc( 4, 'veh_not_handled' );
            $as->mov_imm( 'rax', -1 );
            $as->append_code( pack( 'C', 0xC3 ) );
            $as->mark_label('veh_not_handled');
            $as->mov_imm( 'rax', 0 );
            $as->append_code( pack( 'C', 0xC3 ) );
            $self->_emit_fiber_switch( $target, $as, $driver );
        }
        elsif ( $op =~ /^call_/ ) {

            # ... argument setup ...
            if   ( $self->os eq 'win64' ) { $as->sub_imm( 'rsp', 32 ); }
            if   ( $op eq 'call_func' )   { $as->call_label($target); }
            else                          { $as->call_reg('r11'); }
            if ( $self->os eq 'win64' ) { $as->add_imm( 'rsp', 32 ); }

            # ... return value handling ...
        }
    }

    method _emit_fiber_switch( $target, $as, $driver ) {
        $as->mark_label('M_fiber_switch');
        my $regs = $driver->preserved_regs();
        for my $r (@$regs) { $as->push_reg($r); }
        $as->mov_reg( 'rax', 'rdx' );
        $as->mov_reg( 'r10', 'rcx' );
        $as->load_reg_mem( 'r11', 'r14', $driver->iso_offset('current_fcb') );
        $as->store_mem_disp_reg( 'r11', $driver->fcb_offset('sp'),          'rsp' );
        $as->store_mem_disp_reg( 'r10', $driver->fcb_offset('caller'),      'r11' );
        $as->store_mem_disp_reg( 'r14', $driver->iso_offset('current_fcb'), 'r10' );
        $as->load_reg_mem( 'rsp', 'r10', $driver->fcb_offset('sp') );
        for my $r ( reverse @$regs ) { $as->pop_reg($r); }
        $as->append_code( pack( 'C', 0xC3 ) );
    }

    method _emit_coverage_dump_x64( $as, $driver ) {
        return unless $driver->coverage_table_size > 0;
        $as->mov_imm( 'rcx', -12 );
        $as->call_rva( $driver->import_rva('GetStdHandle'), $driver->text_rva );
        $as->mov_reg( 'r10', 'rax' );
        $as->mov_reg( 'rcx', 'r10' );
        $as->lea_rva( 'rdx', "DATA:" . $driver->coverage_table_offset );
        $as->mov_imm( 'r8', $driver->coverage_table_size );
        $as->lea_reg_disp( 'r9', 'rsp', 40 );
        $as->mov_imm( 'r11', 0 );
        $as->store_mem_disp_reg( 'rsp', 32, 'r11' );
        $as->call_rva( $driver->import_rva('WriteFile'), $driver->text_rva );
    }
}
1;
__END__

=pod

=head1 NAME

Brocken::Platform::Windows - Windows platform support

=head1 SYNOPSIS

    my $platform = Brocken::Platform::Windows->new( os => 'win64' );
    my $name = $platform->format_name; # 'PE'
    my $ss = $platform->shadow_space;  # 32

=head1 DESCRIPTION

Implements the L<Brocken::Platform> interface for Windows (x64). Handles the PE binary format, Windows x64 ABI
requirements (shadow space), and translates intrinsics into Win32 API calls (VirtualAlloc, WriteFile, CreateFileA,
etc.).

=head1 METHODS

=head2 format_name

Returns C<'PE'>.

=head2 shadow_space

Returns C<32>, as required by the Windows x64 ABI for register spill space.

=head2 emit_intrinsic($target, $as, $inst, $reg_map, $driver)

Emits machine code for intrinsics by calling Win32 APIs via the import table.

=cut
