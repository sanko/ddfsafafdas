    use v5.40;
    use feature 'class';
    no warnings 'experimental::class';
    #
    class Brocken::Platform::Linux : isa(Brocken::Platform) {
        method format_name() {'ELF'}

        method emit_intrinsic( $target, $as, $inst, $reg_map, $driver ) {
            my $op = $inst->{op};
            my $v  = sub { $target->val( $reg_map, shift ) };
            if ( $op eq 'intrinsic_alloc' ) {
                my $d = $reg_map->{ $inst->{dest} };
                $as->mov_imm( 'rax', 9 );
                $as->mov_imm( 'rdi', 0 );
                if ( $inst->{args}[0] =~ /^%/ ) { $as->mov_reg( 'rsi', $reg_map->{ $inst->{args}[0] } ); }
                else                            { $as->mov_imm( 'rsi', $v->( $inst->{args}[0] ) ); }
                $as->mov_imm( 'rdx', 3 );
                $as->mov_imm( 'r10', 0x22 );
                $as->mov_imm( 'r8',  -1 );
                $as->mov_imm( 'r9',  0 );
                $as->syscall();
                $as->mov_reg( $d, 'rax' );
            }
            elsif ( $op eq 'intrinsic_print' ) {
                my $p = $reg_map->{ $inst->{args}[0] };
              $as->mov_reg('rsi', $p);
            $as->load_reg_mem('rdx', 'rsi', 0); # Load ByteLen (at offset 0)
            $as->add_imm('rsi', 16);           # Skip ByteLen(8) + CharLen(8) to reach bytes
            $as->mov_imm('rdi', 1);            # stdout
            $as->mov_imm('rax', 1);            # write
                $as->syscall();
            }
            elsif ( $op eq 'intrinsic_print_char' ) {
                my $char = $v->( $inst->{args}[0] );
                my $src  = ( $inst->{args}[0] =~ /^%/ ) ? $reg_map->{ $inst->{args}[0] } : 'r11';
                $as->mov_imm( 'r11', $char ) if $inst->{args}[0] !~ /^%/;
                $as->store_mem_disp_byte( 'rsp', 48, $src );
                $as->mov_imm( 'rax', 1 );
                $as->mov_imm( 'rdi', 1 );
                $as->lea_reg_disp( 'rsi', 'rsp', 48 );
                $as->mov_imm( 'rdx', 1 );
                $as->syscall();
            }
            elsif ( $op eq 'intrinsic_exit' ) {
                my $val = $v->( $inst->{args}[0] );
                $as->mov_imm( 'rax', 60 );
                if ( $inst->{args}[0] =~ /^%/ ) { $as->mov_reg( 'rdi', $val ); }
                else                            { $as->mov_imm( 'rdi', $val // 0 ); }
                $as->syscall();
            }
            elsif ( $op eq 'intrinsic_emit_runtime' ) {
                $as->mark_label('M_fiber_switch');
                my $regs = $driver->preserved_regs();
                for my $r (@$regs) { $as->push_reg($r); }
                $as->mov_reg( 'rax', 'rsi' );
                $as->mov_reg( 'r10', 'rdi' );
                $as->load_reg_mem( 'r11', 'r14', $driver->iso_offset('current_fcb') );
                $as->store_mem_disp_reg( 'r11', $driver->fcb_offset('sp'),          'rsp' );
                $as->store_mem_disp_reg( 'r10', $driver->fcb_offset('caller'),      'r11' );
                $as->store_mem_disp_reg( 'r14', $driver->iso_offset('current_fcb'), 'r10' );
                $as->load_reg_mem( 'rsp', 'r10', $driver->fcb_offset('sp') );
                for my $r ( reverse @$regs ) { $as->pop_reg($r); }
                $as->append_code( pack( 'C', 0xC3 ) );
            }
        }
    }
    1;
