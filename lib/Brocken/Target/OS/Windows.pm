use v5.40;
use feature 'class';
no warnings 'experimental::class';

class Brocken::Target::OS::Windows : isa(Brocken::Target::OS) {
    method format_name()  {'PE'}
    method shadow_space() {32}

    method emit_intrinsic( $target, $as, $inst, $reg_map, $driver ) {
        my $op     = $inst->{op};
        my $v      = sub { $target->val( $reg_map, shift ) };
        my $is_arm = ( $driver->arch eq 'arm64' );
        if ( $op eq 'intrinsic_alloc' ) {
            my $d = $reg_map->{ $inst->{dest} };
            if ($is_arm) {

                # Windows ARM64 AAPCS64 calling convention: no shadow space
                $as->mov_imm( 'x0', 0 );
                if ( $inst->{args}[0] =~ /^%/ ) { $as->mov_reg( 'x1', $reg_map->{ $inst->{args}[0] } ); }
                else                            { $as->mov_imm( 'x1', $v->( $inst->{args}[0] ) ); }
                $as->mov_imm( 'x2', 0x3000 );    # MEM_COMMIT | MEM_RESERVE
                $as->mov_imm( 'x3', 0x04 );      # PAGE_READWRITE
                $as->call_rva( $driver->import_rva('VirtualAlloc'), $driver->text_rva );
                $as->mov_reg( $d, 'x0' );
            }
            else {
                $as->sub_imm( 'rsp', 32 );       # Allocate Shadow Space
                $as->mov_imm( 'rcx', 0 );
                if ( $inst->{args}[0] =~ /^%/ ) { $as->mov_reg( 'rdx', $reg_map->{ $inst->{args}[0] } ); }
                else                            { $as->mov_imm( 'rdx', $v->( $inst->{args}[0] ) ); }
                $as->mov_imm( 'r8', 0x3000 );
                $as->mov_imm( 'r9', 0x04 );
                $as->call_rva( $driver->import_rva('VirtualAlloc'), $driver->text_rva );
                $as->add_imm( 'rsp', 32 );       # Deallocate Shadow Space
                $as->mov_reg( $d, 'rax' );
            }
        }
        elsif ( $op eq 'intrinsic_load_library' ) {
            my $d = $reg_map->{ $inst->{dest} };
            if ($is_arm) {
                $as->mov_reg( 'x0', $reg_map->{ $inst->{args}[0] } );
                $as->add_imm( 'x0', 16 );
                $as->call_rva( $driver->import_rva('LoadLibraryA'), $driver->text_rva );
                $as->mov_reg( $d, 'x0' );
            }
            else {
                $as->sub_imm( 'rsp', 32 );
                $as->mov_reg( 'rcx', $reg_map->{ $inst->{args}[0] } );
                $as->add_imm( 'rcx', 16 );
                $as->call_rva( $driver->import_rva('LoadLibraryA'), $driver->text_rva );
                $as->add_imm( 'rsp', 32 );
                $as->mov_reg( $d, 'rax' );
            }
        }
        elsif ( $op eq 'intrinsic_get_proc_address' ) {
            my $d = $reg_map->{ $inst->{dest} };
            if ($is_arm) {
                $as->mov_reg( 'x0', $reg_map->{ $inst->{args}[0] } );
                $as->mov_reg( 'x1', $reg_map->{ $inst->{args}[1] } );
                $as->add_imm( 'x1', 16 );
                $as->call_rva( $driver->import_rva('GetProcAddress'), $driver->text_rva );
                $as->mov_reg( $d, 'x0' );
            }
            else {
                $as->sub_imm( 'rsp', 32 );
                $as->mov_reg( 'rcx', $reg_map->{ $inst->{args}[0] } );
                $as->mov_reg( 'rdx', $reg_map->{ $inst->{args}[1] } );
                $as->add_imm( 'rdx', 16 );
                $as->call_rva( $driver->import_rva('GetProcAddress'), $driver->text_rva );
                $as->add_imm( 'rsp', 32 );
                $as->mov_reg( $d, 'rax' );
            }
        }
        elsif ( $op eq 'intrinsic_get_env_block' ) {
            my $d = $reg_map->{ $inst->{dest} };
            if ($is_arm) {
                $as->call_rva( $driver->import_rva('GetEnvironmentStringsA'), $driver->text_rva );
                $as->mov_reg( $d, 'x0' );
            }
            else {
                $as->sub_imm( 'rsp', 32 );
                $as->call_rva( $driver->import_rva('GetEnvironmentStringsA'), $driver->text_rva );
                $as->add_imm( 'rsp', 32 );
                $as->mov_reg( $d, 'rax' );
            }
        }
        elsif ( $op eq 'intrinsic_free_env_block' ) {
            if ($is_arm) {
                $as->mov_reg( 'x0', $reg_map->{ $inst->{args}[0] } );
                $as->call_rva( $driver->import_rva('FreeEnvironmentStringsA'), $driver->text_rva );
            }
            else {
                $as->sub_imm( 'rsp', 32 );
                $as->mov_reg( 'rcx', $reg_map->{ $inst->{args}[0] } );
                $as->call_rva( $driver->import_rva('FreeEnvironmentStringsA'), $driver->text_rva );
                $as->add_imm( 'rsp', 32 );
            }
        }
        elsif ( $op eq 'intrinsic_get_pid' ) {
            my $d = $reg_map->{ $inst->{dest} };
            if ($is_arm) {
                $as->call_rva( $driver->import_rva('GetCurrentProcessId'), $driver->text_rva );
                $as->mov_reg( $d, 'x0' );
            }
            else {
                $as->sub_imm( 'rsp', 32 );
                $as->call_rva( $driver->import_rva('GetCurrentProcessId'), $driver->text_rva );
                $as->add_imm( 'rsp', 32 );
                $as->mov_reg( $d, 'rax' );
            }
        }
        elsif ( $op eq 'intrinsic_get_system_filetime' ) {
            my $d = $reg_map->{ $inst->{dest} };
            if ($is_arm) {
                $as->sub_imm( 'sp', 16 );
                $as->mov_reg( 'x0', 'sp' );
                $as->call_rva( $driver->import_rva('GetSystemTimeAsFileTime'), $driver->text_rva );
                $as->load_reg_mem( $d, 'sp', 0 );
                $as->add_imm( 'sp', 16 );
            }
            else {
                $as->sub_imm( 'rsp', 32 );
                $as->mov_reg( 'rcx', 'rsp' );
                $as->call_rva( $driver->import_rva('GetSystemTimeAsFileTime'), $driver->text_rva );
                $as->load_reg_mem( $d, 'rsp', 0 );
                $as->add_imm( 'rsp', 32 );
            }
        }
        elsif ( $op eq 'intrinsic_get_module_filename' ) {
            my $d = $reg_map->{ $inst->{dest} };
            if ($is_arm) {
                $as->mov_imm( 'x0', 0 );
                $as->mov_reg( 'x1', $reg_map->{ $inst->{args}[0] } );
                $as->mov_imm( 'x2', 512 );
                $as->call_rva( $driver->import_rva('GetModuleFileNameA'), $driver->text_rva );
                $as->mov_reg( $d, 'x0' );
            }
            else {
                $as->sub_imm( 'rsp', 32 );
                $as->mov_imm( 'rcx', 0 );
                $as->mov_reg( 'rdx', $reg_map->{ $inst->{args}[0] } );
                $as->mov_imm( 'r8', 512 );
                $as->call_rva( $driver->import_rva('GetModuleFileNameA'), $driver->text_rva );
                $as->add_imm( 'rsp', 32 );
                $as->mov_reg( $d, 'rax' );
            }
        }
        elsif ( $op eq 'intrinsic_get_cmd_line' ) {
            my $d = $reg_map->{ $inst->{dest} };
            if ($is_arm) {
                $as->call_rva( $driver->import_rva('GetCommandLineA'), $driver->text_rva );
                $as->mov_reg( $d, 'x0' );
            }
            else {
                $as->sub_imm( 'rsp', 32 );
                $as->call_rva( $driver->import_rva('GetCommandLineA'), $driver->text_rva );
                $as->add_imm( 'rsp', 32 );
                $as->mov_reg( $d, 'rax' );
            }
        }
        elsif ( $op eq 'intrinsic_get_stdout_handle' ) {
            my $d = $reg_map->{ $inst->{dest} };
            if ($is_arm) {
                $as->mov_imm( 'x0', -11 );
                $as->call_rva( $driver->import_rva('GetStdHandle'), $driver->text_rva );
                $as->mov_reg( $d, 'x0' );
            }
            else {
                $as->sub_imm( 'rsp', 32 );
                $as->mov_imm( 'rcx', -11 );
                $as->call_rva( $driver->import_rva('GetStdHandle'), $driver->text_rva );
                $as->add_imm( 'rsp', 32 );
                $as->mov_reg( $d, 'rax' );
            }
        }
        elsif ( $op eq 'intrinsic_get_stderr_handle' ) {
            my $d = $reg_map->{ $inst->{dest} };
            if ($is_arm) {
                $as->mov_imm( 'x0', -12 );
                $as->call_rva( $driver->import_rva('GetStdHandle'), $driver->text_rva );
                $as->mov_reg( $d, 'x0' );
            }
            else {
                $as->sub_imm( 'rsp', 32 );
                $as->mov_imm( 'rcx', -12 );
                $as->call_rva( $driver->import_rva('GetStdHandle'), $driver->text_rva );
                $as->add_imm( 'rsp', 32 );
                $as->mov_reg( $d, 'rax' );
            }
        }
        elsif ( $op eq 'intrinsic_get_stdin_handle' ) {
            my $d = $reg_map->{ $inst->{dest} };
            if ($is_arm) {
                $as->mov_imm( 'x0', -10 );
                $as->call_rva( $driver->import_rva('GetStdHandle'), $driver->text_rva );
                $as->mov_reg( $d, 'x0' );
            }
            else {
                $as->sub_imm( 'rsp', 32 );
                $as->mov_imm( 'rcx', -10 );
                $as->call_rva( $driver->import_rva('GetStdHandle'), $driver->text_rva );
                $as->add_imm( 'rsp', 32 );
                $as->mov_reg( $d, 'rax' );
            }
        }
        elsif ( $op eq 'intrinsic_spawn_thread' ) {
            my $d = $reg_map->{ $inst->{dest} };
            if ($is_arm) {
                $as->sub_imm( 'sp', 16 );
                $as->mov_imm( 'x0', 0 );
                $as->mov_imm( 'x1', 0 );
                $as->lea_rva( 'x2', 'M_thread_entry', $driver->text_rva );
                $as->mov_reg( 'x3', $reg_map->{ $inst->{args}[0] } );
                $as->mov_imm( 'x4', 0 );
                $as->store_mem_disp_reg( 'sp', 0, 'x4' );
                $as->store_mem_disp_reg( 'sp', 8, 'x4' );
                $as->call_rva( $driver->import_rva('CreateThread'), $driver->text_rva );
                $as->add_imm( 'sp', 16 );
                $as->mov_reg( $d, 'x0' );
            }
            else {
                $as->sub_imm( 'rsp', 48 );
                $as->mov_imm( 'rcx', 0 );
                $as->mov_imm( 'rdx', 0 );
                $as->lea_rva( 'r8', 'M_thread_entry', $driver->text_rva );
                $as->mov_reg( 'r9', $reg_map->{ $inst->{args}[0] } );
                $as->mov_imm( 'rax', 0 );
                $as->store_mem_disp_reg( 'rsp', 32, 'rax' );
                $as->store_mem_disp_reg( 'rsp', 40, 'rax' );
                $as->call_rva( $driver->import_rva('CreateThread'), $driver->text_rva );
                $as->add_imm( 'rsp', 48 );
                $as->mov_reg( $d, 'rax' );
            }
        }
        elsif ( $op eq 'intrinsic_print' || $op eq 'intrinsic_print_char' ) {
            my $is_char = ( $op eq 'intrinsic_print_char' );
            my $p       = $reg_map->{ $inst->{args}[0] };
            if ($is_arm) {
                $as->sub_imm( 'sp', 48 );
                if ($is_char) {
                    my $src = ( $inst->{args}[0] =~ /^%/ ) ? $p : 'x16';
                    $as->mov_imm( 'x16', $v->( $inst->{args}[0] ) ) if $inst->{args}[0] !~ /^%/;
                    $as->sturb_mem_disp_reg( 'sp', 40, $src );
                }
                $as->mov_imm( 'x0', -11 );                    # STD_OUTPUT_HANDLE
                $as->call_rva( $driver->import_rva('GetStdHandle'), $driver->text_rva );
                $as->store_mem_disp_reg( 'sp', 32, 'x0' );    # Safe temporary stack backup
                $as->load_reg_mem( 'x0', 'sp', 32 );
                if ($is_char) {
                    $as->lea_reg_disp( 'x1', 'sp', 40 );
                    $as->mov_imm( 'x2', 1 );
                }
                else {
                    $as->mov_reg( 'x1', $p );
                    $as->add_imm( 'x1', 16 );
                    $as->load_reg_mem( 'x2', $p, 0 );
                }
                $as->lea_reg_disp( 'x3', 'sp', 44 );          # &written
                $as->mov_imm( 'x4', 0 );                      # lpOverlapped = NULL
                $as->call_rva( $driver->import_rva('WriteFile'), $driver->text_rva );
                $as->add_imm( 'sp', 48 );
            }
            else {
                $as->sub_imm( 'rsp', 48 );                    # Allocate Shadow Space + 16 bytes for parameter passing/alignment
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
        }
        elsif ( $op eq 'intrinsic_print_stderr' ) {
            my $p = $reg_map->{ $inst->{args}[0] };
            if ($is_arm) {
                $as->sub_imm( 'sp', 48 );
                $as->mov_imm( 'x0', -12 );
                $as->call_rva( $driver->import_rva('GetStdHandle'), $driver->text_rva );
                $as->store_mem_disp_reg( 'sp', 32, 'x0' );
                $as->load_reg_mem( 'x0', 'sp', 32 );
                $as->mov_reg( 'x1', $p );
                $as->add_imm( 'x1', 16 );
                $as->load_reg_mem( 'x2', $p, 0 );
                $as->lea_reg_disp( 'x3', 'sp', 44 );
                $as->mov_imm( 'x4', 0 );
                $as->call_rva( $driver->import_rva('WriteFile'), $driver->text_rva );
                $as->add_imm( 'sp', 48 );
            }
            else {
                $as->sub_imm( 'rsp', 48 );        # Allocate Shadow Space + 16 bytes for parameter passing/alignment
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
                $as->add_imm( 'rsp', 48 );        # Deallocate Shadow Space
            }
        }
        elsif ( $op eq 'intrinsic_print_stderr_char' ) {
            if ($is_arm) {
                my $src = ( $inst->{args}[0] =~ /^%/ ) ? $reg_map->{ $inst->{args}[0] } : 'x16';
                $as->mov_imm( 'x16', $v->( $inst->{args}[0] ) ) if $inst->{args}[0] !~ /^%/;
                $as->sub_imm( 'sp', 48 );
                $as->sturb_mem_disp_reg( 'sp', 40, $src );
                $as->mov_imm( 'x0', -12 );
                $as->call_rva( $driver->import_rva('GetStdHandle'), $driver->text_rva );
                $as->store_mem_disp_reg( 'sp', 32, 'x0' );
                $as->load_reg_mem( 'x0', 'sp', 32 );
                $as->lea_reg_disp( 'x1', 'sp', 40 );
                $as->mov_imm( 'x2', 1 );
                $as->lea_reg_disp( 'x3', 'sp', 44 );
                $as->mov_imm( 'x4', 0 );
                $as->call_rva( $driver->import_rva('WriteFile'), $driver->text_rva );
                $as->add_imm( 'sp', 48 );
            }
            else {
                my $src = ( $inst->{args}[0] =~ /^%/ ) ? $reg_map->{ $inst->{args}[0] } : 'r11';
                $as->mov_imm( 'r11', $v->( $inst->{args}[0] ) ) if $inst->{args}[0] !~ /^%/;
                $as->sub_imm( 'rsp', 48 );        # Allocate Shadow Space + 16 bytes for parameter passing/alignment
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
                $as->add_imm( 'rsp', 48 );        # Deallocate Shadow Space
            }
        }
        elsif ( $op eq 'intrinsic_open' ) {
            my ( $path, $mode ) = ( $reg_map->{ $inst->{args}[0] }, $reg_map->{ $inst->{args}[1] } );
            state $open_id = 0;
            my $l_write = "intr_open_write_" . ++$open_id;
            my $l_call  = "intr_open_call_" . $open_id;
            if ($is_arm) {
                $as->sub_imm( 'sp', 32 );
                $as->mov_reg( 'x0', $path );
                $as->add_imm( 'x0', 16 );
                $as->load_reg_mem_byte( 'x4', $mode, 16 );
                $as->cmp_reg_imm( 'x4', ord('r') );
                $as->jcc( $driver->cc('ne'), $l_write );

                # Read Mode
                $as->mov_imm( 'x1', 0x80000000 );
                $as->mov_imm( 'x2', 1 );
                $as->mov_imm( 'x3', 0 );
                $as->mov_imm( 'x4', 3 );
                $as->store_mem_disp_reg( 'sp', 0, 'x4' );
                $as->mov_imm( 'x4', 0x80 );
                $as->store_mem_disp_reg( 'sp', 8, 'x4' );
                $as->mov_imm( 'x4', 0 );
                $as->store_mem_disp_reg( 'sp', 16, 'x4' );
                $as->jmp($l_call);
                $as->mark_label($l_write);

                # Write Mode
                $as->mov_imm( 'x1', 0x40000000 );
                $as->mov_imm( 'x2', 0 );
                $as->mov_imm( 'x3', 0 );
                $as->mov_imm( 'x4', 2 );
                $as->store_mem_disp_reg( 'sp', 0, 'x4' );
                $as->mov_imm( 'x4', 0x80 );
                $as->store_mem_disp_reg( 'sp', 8, 'x4' );
                $as->mov_imm( 'x4', 0 );
                $as->store_mem_disp_reg( 'sp', 16, 'x4' );
                $as->mark_label($l_call);
                $as->call_rva( $driver->import_rva('CreateFileA'), $driver->text_rva );
                $as->add_imm( 'sp', 32 );
                $as->mov_reg( $reg_map->{ $inst->{dest} }, 'x0' );
            }
            else {
                $as->sub_imm( 'rsp', 64 );
                $as->mov_reg( 'rcx', $path );
                $as->add_imm( 'rcx', 16 );
                $as->load_reg_mem_byte( 'rax', $mode, 16 );
                $as->cmp_reg_imm( 'rax', ord('r') );
                $as->jcc( $driver->cc('ne'), $l_write );

                # Read Mode
                $as->mov_imm( 'rdx', 0x80000000 );
                $as->mov_imm( 'r8',  1 );
                $as->mov_imm( 'r9',  0 );
                $as->mov_imm( 'rax', 3 );
                $as->store_mem_disp_reg( 'rsp', 32, 'rax' );
                $as->mov_imm( 'rax', 0x80 );
                $as->store_mem_disp_reg( 'rsp', 40, 'rax' );
                $as->mov_imm( 'rax', 0 );
                $as->store_mem_disp_reg( 'rsp', 48, 'rax' );
                $as->jmp($l_call);
                $as->mark_label($l_write);

                # Write Mode
                $as->mov_imm( 'rdx', 0x40000000 );
                $as->mov_imm( 'r8',  0 );
                $as->mov_imm( 'r9',  0 );
                $as->mov_imm( 'rax', 2 );
                $as->store_mem_disp_reg( 'rsp', 32, 'rax' );
                $as->mov_imm( 'rax', 0x80 );
                $as->store_mem_disp_reg( 'rsp', 40, 'rax' );
                $as->mov_imm( 'rax', 0 );
                $as->store_mem_disp_reg( 'rsp', 48, 'rax' );
                $as->mark_label($l_call);
                $as->call_rva( $driver->import_rva('CreateFileA'), $driver->text_rva );
                $as->add_imm( 'rsp', 64 );
                $as->mov_reg( $reg_map->{ $inst->{dest} }, 'rax' );
            }
        }
        elsif ( $op eq 'intrinsic_get_size' ) {
            if ($is_arm) {
                $as->sub_imm( 'sp', 16 );
                $as->mov_reg( 'x0', $reg_map->{ $inst->{args}[0] } );
                $as->lea_reg_disp( 'x1', 'sp', 0 );
                $as->call_rva( $driver->import_rva('GetFileSizeEx'), $driver->text_rva );
                $as->load_reg_mem( $reg_map->{ $inst->{dest} }, 'sp', 0 );
                $as->add_imm( 'sp', 16 );
            }
            else {
                $as->sub_imm( 'rsp', 48 );
                $as->mov_reg( 'rcx', $reg_map->{ $inst->{args}[0] } );
                $as->lea_reg_disp( 'rdx', 'rsp', 32 );
                $as->call_rva( $driver->import_rva('GetFileSizeEx'), $driver->text_rva );
                $as->load_reg_mem( $reg_map->{ $inst->{dest} }, 'rsp', 32 );
                $as->add_imm( 'rsp', 48 );
            }
        }
        elsif ( $op eq 'intrinsic_read' ) {
            if ($is_arm) {
                $as->sub_imm( 'sp', 16 );
                $as->mov_reg( 'x0', $reg_map->{ $inst->{args}[0] } );
                $as->mov_reg( 'x1', $reg_map->{ $inst->{args}[1] } );
                $as->mov_reg( 'x2', $reg_map->{ $inst->{args}[2] } );
                $as->lea_reg_disp( 'x3', 'sp', 8 );
                $as->mov_imm( 'x4', 0 );
                $as->store_mem_disp_reg( 'sp', 0, 'x4' );
                $as->call_rva( $driver->import_rva('ReadFile'), $driver->text_rva );
                $as->add_imm( 'sp', 16 );
            }
            else {
                $as->sub_imm( 'rsp', 48 );
                $as->mov_reg( 'rcx', $reg_map->{ $inst->{args}[0] } );
                $as->mov_reg( 'rdx', $reg_map->{ $inst->{args}[1] } );
                $as->mov_reg( 'r8',  $reg_map->{ $inst->{args}[2] } );
                $as->lea_reg_disp( 'r9', 'rsp', 40 );
                $as->mov_imm( 'rax', 0 );
                $as->store_mem_disp_reg( 'rsp', 32, 'rax' );
                $as->call_rva( $driver->import_rva('ReadFile'), $driver->text_rva );
                $as->add_imm( 'rsp', 48 );
            }
        }
        elsif ( $op eq 'intrinsic_write' ) {
            if ($is_arm) {
                $as->sub_imm( 'sp', 16 );
                $as->mov_reg( 'x0', $reg_map->{ $inst->{args}[0] } );
                $as->mov_reg( 'x1', $reg_map->{ $inst->{args}[1] } );
                $as->mov_reg( 'x2', $reg_map->{ $inst->{args}[2] } );
                $as->lea_reg_disp( 'x3', 'sp', 8 );
                $as->mov_imm( 'x4', 0 );
                $as->store_mem_disp_reg( 'sp', 0, 'x4' );
                $as->call_rva( $driver->import_rva('WriteFile'), $driver->text_rva );
                $as->add_imm( 'sp', 16 );
            }
            else {
                $as->sub_imm( 'rsp', 48 );
                $as->mov_reg( 'rcx', $reg_map->{ $inst->{args}[0] } );
                $as->mov_reg( 'rdx', $reg_map->{ $inst->{args}[1] } );
                $as->mov_reg( 'r8',  $reg_map->{ $inst->{args}[2] } );
                $as->lea_reg_disp( 'r9', 'rsp', 40 );
                $as->mov_imm( 'rax', 0 );
                $as->store_mem_disp_reg( 'rsp', 32, 'rax' );
                $as->call_rva( $driver->import_rva('WriteFile'), $driver->text_rva );
                $as->add_imm( 'rsp', 48 );
            }
        }
        elsif ( $op eq 'intrinsic_close' ) {
            if ($is_arm) {
                $as->mov_reg( 'x0', $reg_map->{ $inst->{args}[0] } );
                $as->call_rva( $driver->import_rva('CloseHandle'), $driver->text_rva );
            }
            else {
                $as->sub_imm( 'rsp', 32 );
                $as->mov_reg( 'rcx', $reg_map->{ $inst->{args}[0] } );
                $as->call_rva( $driver->import_rva('CloseHandle'), $driver->text_rva );
                $as->add_imm( 'rsp', 32 );
            }
        }
        elsif ( $op eq 'intrinsic_create_wait_handle' ) {
            if ($is_arm) {
                $as->mov_imm( 'x0', 0 );
                $as->mov_imm( 'x1', 0 );
                $as->mov_imm( 'x2', 0 );
                $as->mov_imm( 'x3', 0 );
                $as->call_rva( $driver->import_rva('CreateEventA'), $driver->text_rva );
                $as->mov_reg( $reg_map->{ $inst->{dest} }, 'x0' );
            }
            else {
                $as->sub_imm( 'rsp', 32 );
                $as->mov_imm( 'rcx', 0 );
                $as->mov_imm( 'rdx', 0 );
                $as->mov_imm( 'r8',  0 );
                $as->mov_imm( 'r9',  0 );
                $as->call_rva( $driver->import_rva('CreateEventA'), $driver->text_rva );
                $as->add_imm( 'rsp', 32 );
                $as->mov_reg( $reg_map->{ $inst->{dest} }, 'rax' );
            }
        }
        elsif ( $op eq 'intrinsic_sleep' ) {
            my $val = $v->( $inst->{args}[0] );
            if ($is_arm) {
                $as->load_reg_mem( 'x16', 'x28', $driver->iso_offset('current_fcb') );
                $as->load_reg_mem( 'x0', 'x16', $driver->fcb_offset('wait_handle') );
                if ( $inst->{args}[0] =~ /^%/ ) {
                    $as->mov_reg( 'x1', $reg_map->{ $inst->{args}[0] } );
                    $as->shr_imm( 'x1', 1 );
                    $as->mov_imm( 'x16', 1000 );
                    $as->mul_reg( 'x1', 'x1', 'x16' );
                }
                else {
                    $as->mov_imm( 'x1', (($val >> 1) * 1000) );
                }
                $as->call_rva( $driver->import_rva('WaitForSingleObject'), $driver->text_rva );
            }
            else {
                $as->load_reg_mem( 'r11', 'r14', $driver->iso_offset('current_fcb') );
                $as->load_reg_mem( 'rcx', 'r11', $driver->fcb_offset('wait_handle') );
                $as->mov_reg( 'rdx', ( $inst->{args}[0] =~ /^%/ ) ? $reg_map->{ $inst->{args}[0] } : 'r11' );
                $as->mov_imm( 'r11', $val ) if $inst->{args}[0] !~ /^%/;
                $as->shr_imm( 'rdx', 1 );
                $as->mov_imm( 'rax', 1000 );
                $as->mul_reg( 'rdx', 'rax' );
                $as->sub_imm( 'rsp', 32 );
                $as->call_rva( $driver->import_rva('WaitForSingleObject'), $driver->text_rva );
                $as->add_imm( 'rsp', 32 );
            }
        }
        elsif ( $op eq 'intrinsic_interrupt' ) {
            if ($is_arm) {
                $as->load_reg_mem( 'x0', $reg_map->{ $inst->{args}[0] }, $driver->fcb_offset('wait_handle') );
                $as->call_rva( $driver->import_rva('SetEvent'), $driver->text_rva );
            }
            else {
                $as->sub_imm( 'rsp', 32 );
                $as->load_reg_mem( 'rcx', $reg_map->{ $inst->{args}[0] }, $driver->fcb_offset('wait_handle') );
                $as->call_rva( $driver->import_rva('SetEvent'), $driver->text_rva );
                $as->add_imm( 'rsp', 32 );
            }
        }
        elsif ( $op eq 'intrinsic_exit' ) {
            if ( $driver->coverage && $driver->coverage_table_size > 0 ) {
                if ($is_arm) {
                    $as->sub_imm( 'sp', 16 );
                    $as->mov_imm( 'x0', -12 );
                    $as->call_rva( $driver->import_rva('GetStdHandle'), $driver->text_rva );
                    $as->mov_reg( 'x1', 'x0' );
                    $as->lea_rva( 'x2', "DATA:" . $driver->coverage_table_offset );
                    $as->mov_imm( 'x3', $driver->coverage_table_size );
                    $as->lea_reg_disp( 'x4', 'sp', 0 );
                    $as->mov_imm( 'x5', 0 );
                    $as->call_rva( $driver->import_rva('WriteFile'), $driver->text_rva );
                    $as->add_imm( 'sp', 16 );
                }
                else {
                    $self->_emit_coverage_dump_x64( $as, $driver );
                }
            }
            my $val = $v->( $inst->{args}[0] );
            if ($is_arm) {
                if ( $inst->{args}[0] =~ /^%/ ) {
                    $as->mov_reg( 'x0', $val );
                    $as->shr_imm( 'x0', 1 );
                }
                else {
                    my $untagged = ( defined $val && $val =~ /^\d+$/ ) ? ( $val >> 1 ) : ( $val // 0 );
                    $as->mov_imm( 'x0', $untagged );
                }
                $as->call_rva( $driver->import_rva('ExitProcess'), $driver->text_rva );
            }
            else {
                $as->sub_imm( 'rsp', 32 );
                if ( $inst->{args}[0] =~ /^%/ ) {
                    $as->mov_reg( 'rcx', $val );
                    $as->shr_imm( 'rcx', 1 );
                }
                else {
                    my $untagged = ( defined $val && $val =~ /^\d+$/ ) ? ( $val >> 1 ) : ( $val // 0 );
                    $as->mov_imm( 'rcx', $untagged );
                }
                $as->call_rva( $driver->import_rva('ExitProcess'), $driver->text_rva );
            }
        }
        elsif ( $op eq 'intrinsic_setup_env' ) {
            if ($is_arm) {
                $as->mov_imm( 'x0', 65001 );
                $as->call_rva( $driver->import_rva('SetConsoleOutputCP'), $driver->text_rva );
            }
            else {
                $as->sub_imm( 'rsp', 32 );
                $as->mov_imm( 'rcx', 65001 );
                $as->call_rva( $driver->import_rva('SetConsoleOutputCP'), $driver->text_rva );
                $as->add_imm( 'rsp', 32 );
            }
        }
        elsif ( $op eq 'intrinsic_setup_fault_handler' ) {
            if ($is_arm) {
                $as->mov_imm( 'x0', 1 );
                $as->lea_rva( 'x1', 'M_veh_handler', $driver->text_rva );
                $as->call_rva( $driver->import_rva('AddVectoredExceptionHandler'), $driver->text_rva );
            }
            else {
                $as->sub_imm( 'rsp', 32 );
                $as->mov_imm( 'rcx', 1 );
                $as->lea_rva( 'rdx', 'M_veh_handler', $driver->text_rva );
                $as->call_rva( $driver->import_rva('AddVectoredExceptionHandler'), $driver->text_rva );
                $as->add_imm( 'rsp', 32 );
            }
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

Brocken::Target::OS::Windows - Windows platform support

=head1 SYNOPSIS

    my $platform = Brocken::Target::OS::Windows->new( os => 'win64' );
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
