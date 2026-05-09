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
            $as->mov_imm( 'rcx', 0 );
            if ( $inst->{args}[0] =~ /^%/ ) { $as->mov_reg( 'rdx', $reg_map->{ $inst->{args}[0] } ); }
            else                            { $as->mov_imm( 'rdx', $v->( $inst->{args}[0] ) ); }
            $as->mov_imm( 'r8', 0x3000 );
            $as->mov_imm( 'r9', 0x04 );
            $as->call_rva( $driver->import_rva('VirtualAlloc'), $driver->text_rva );
            $as->mov_reg( $d, 'rax' );
        }
        elsif ( $op eq 'intrinsic_print' || $op eq 'intrinsic_print_char' ) {
            my $is_char = ( $op eq 'intrinsic_print_char' );
            my $p       = $reg_map->{ $inst->{args}[0] };
            if ($is_char) {
                my $src = ( $inst->{args}[0] =~ /^%/ ) ? $p : 'r11';
                $as->mov_imm( 'r11', $v->( $inst->{args}[0] ) ) if $inst->{args}[0] !~ /^%/;
                $as->store_mem_disp_byte( 'rsp', 48, $src );
            }
            $as->mov_imm( 'rcx', -11 );
            $as->call_rva( $driver->import_rva('GetStdHandle'), $driver->text_rva );
            $as->mov_reg( 'rcx', 'rax' );
            if ($is_char) { $as->lea_reg_disp( 'rdx', 'rsp', 48 ); $as->mov_imm( 'r8', 1 ); }
            else          { $as->mov_reg( 'rdx', $p ); $as->add_imm( 'rdx', 16 ); $as->load_reg_mem( 'r8', $p, 0 ); }
            $as->lea_reg_disp( 'r9', 'rsp', 40 );
            $as->mov_imm( 'rax', 0 );
            $as->store_mem_disp_reg( 'rsp', 32, 'rax' );
            $as->call_rva( $driver->import_rva('WriteFile'), $driver->text_rva );
        }
        elsif ( $op eq 'intrinsic_exit' ) {
            my $val = $v->( $inst->{args}[0] );
            $as->mov_reg( 'rcx', $val )      if $inst->{args}[0] =~ /^%/;
            $as->mov_imm( 'rcx', $val // 0 ) if $inst->{args}[0] !~ /^%/;
            $as->call_rva( $driver->import_rva('ExitProcess'), $driver->text_rva );
        }
        elsif ( $op eq 'intrinsic_setup_env' ) {
            $as->mov_imm( 'rcx', 65001 );
            $as->call_rva( $driver->import_rva('SetConsoleOutputCP'), $driver->text_rva );
        }
        elsif ( $op eq 'intrinsic_setup_fault_handler' ) {
            $as->mov_imm( 'rcx', 1 );
            $as->lea_rva( 'rdx', 'M_veh_handler', $driver->text_rva );
            $as->call_rva( $driver->import_rva('AddVectoredExceptionHandler'), $driver->text_rva );
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
}
1;
