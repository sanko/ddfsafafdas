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
                $as->append_code( pack( 'CCCC', 0x48, 0x8D, 0x74, 0x24 ) . pack( 'C', 48 ) );    # lea rsi, [rsp+48]
                $as->mov_imm( 'rdx', 1 );
                $as->syscall();
            }
            else {
                my $src = ( $inst->{args}[0] =~ /^%/ ) ? $reg_map->{ $inst->{args}[0] } : 'x17';
                $as->mov_imm( 'x17', $char ) if $inst->{args}[0] !~ /^%/;
                $as->sturb_mem_disp_reg( 'sp', 48, $src );
                $as->mov_imm( 'x16', $SYS_write );
                $as->mov_imm( 'x0',  1 );
                $as->add_imm( 'x17', 0 );                                                        # dummy to get SP
                $as->mov_reg( 'x1', 'sp' );
                $as->add_imm( 'x1', 48 );
                $as->mov_imm( 'x2', 1 );
                $as->syscall(1);
            }
        }
        elsif ( $op eq 'intrinsic_exit' ) {
            my $val = $v->( $inst->{args}[0] );
            if ( $arch eq 'x64' ) {
                $as->mov_imm( 'rax', $SYS_exit );
                if ( $inst->{args}[0] =~ /^%/ ) { $as->mov_reg( 'rdi', $val ); }
                else                            { $as->mov_imm( 'rdi', $val // 0 ); }
                $as->syscall();
            }
            else {
                $as->mov_imm( 'x16', $SYS_exit );
                if ( $inst->{args}[0] =~ /^%/ ) { $as->mov_reg( 'x0', $val ); }
                else                            { $as->mov_imm( 'x0', $val // 0 ); }
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
