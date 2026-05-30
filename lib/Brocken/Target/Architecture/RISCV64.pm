use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';

class Brocken::Target::Architecture::RISCV64 : isa(Brocken::Target) {
    method registers() {
        return [qw(s1 s2 s3 s4 s5 s6 s7 s8 s9 s10)];
    }

    method fp_registers() {
        return [qw(fs0 fs1 fs2 fs3 fs4 fs5 fs6 fs7 fs8 fs9 fs10 fs11)];
    }

    method _abi_arg_reg($idx) {
        return (qw[a0 a1 a2 a3 a4 a5 a6 a7])[$idx] // $idx;
    }

    method _abi_fp_arg_reg($idx) {
        return (qw[fa0 fa1 fa2 fa3 fa4 fa5 fa6 fa7])[$idx] // "fa$idx";
    }

    method _abi_fp_return_reg() {
        return 'fa0';
    }

    method compile_intrinsic( $as, $inst, $reg_map, $driver ) {
        my $op    = $inst->{op};
        my $v     = sub { $self->val( $reg_map, shift ) };
        my $d_reg = $reg_map->{ $inst->{dest} } if $inst->{dest};

        if ( $op eq 'intrinsic_get_text_base' ) {
            $as->lea_rva( $d_reg, 0, $driver->text_rva );
            return;
        }

        return $driver->platform->emit_intrinsic( $self, $as, $inst, $reg_map, $driver );
    }

    method new_assembler() {
        return Brocken::Target::Architecture::RISCV64::Emit->new();
    }

    method emit_op( $as, $inst, $reg_map, $driver ) {
        my $op    = $inst->{op};
        my $v     = sub { $self->val( $reg_map, shift ) };
        my $d_reg = $reg_map->{ $inst->{dest} } if $inst->{dest};

        if    ( $op eq 'jmp' ) { $as->jmp( $inst->{target} ); }
        elsif ( $op eq 'cond_br' ) {
            my $reg = $v->( $inst->{reg} );
            $as->cmp_reg_imm( $reg, 0 );
            $as->jcc( $driver->cc('ne'), $inst->{true_l} );
            $as->jmp( $inst->{false_l} );
        }
        elsif ( $op eq 'constant' ) {
            $as->mov_imm( $d_reg, $inst->{args}[0] );
        }
        elsif ( $op eq 'mov' ) {
            my $src = $inst->{args}[0];
            if ( $src =~ /^%/ ) { $as->mov_reg( $d_reg, $reg_map->{$src} ) if $d_reg ne $reg_map->{$src}; }
            else                { $as->mov_imm( $d_reg, $v->($src) ); }
        }
        elsif ( $op eq 'ret' ) {
            $as->ret();
        }
        elsif ( $op eq 'call_label' ) {
            # RISC-V call to label usually uses JAL
            # For simplicity in this dummy/initial version, we use a fixup
            $as->call_label( $inst->{target} );
        }
        elsif ( $op eq 'call_rva' ) {
            $as->call_rva( $inst->{target}, $driver->text_rva );
        }
        elsif ( $op eq 'label' ) {
            $as->mark_label( $inst->{name} );
        }
    }
}

class Brocken::Target::Architecture::RISCV64::Emit {
    state $REG_MAP = {
        zero => 0,  ra => 1,  sp => 2,  gp => 3,  tp => 4,  t0 => 5,  t1 => 6,  t2 => 7,
        s0   => 8,  s1 => 9,  a0 => 10, a1 => 11, a2 => 12, a3 => 13, a4 => 14, a5 => 15,
        a6   => 16, a7 => 17, s2 => 18, s3 => 19, s4 => 20, s5 => 21, s6 => 22, s7 => 23,
        s8   => 24, s9 => 25, s10 => 26, s11 => 27, t3 => 28, t4 => 29, t5 => 30, t6 => 31,
        # Standard names
        x0  => 0,  x1  => 1,  x2  => 2,  x3  => 3,  x4  => 4,  x5  => 5,  x6  => 6,  x7  => 7,
        x8  => 8,  x9  => 9,  x10 => 10, x11 => 11, x12 => 12, x13 => 13, x14 => 14, x15 => 15,
        x16 => 16, x17 => 17, x18 => 18, x19 => 19, x20 => 20, x21 => 21, x22 => 22, x23 => 23,
        x24 => 24, x25 => 25, x26 => 26, x27 => 27, x28 => 28, x29 => 29, x30 => 30, x31 => 31,
        # Aliases for cross-arch platform code
        rsp => 2,  rbp => 8,  rax => 10, rdi => 10, rsi => 11, rdx => 12, rcx => 13, r8 => 14, r9 => 15,
        r10 => 28, r11 => 29, r14 => 25, # tp/r14? No, let's use s9 for r14 if we need a scratch
    };

    field $code : reader = '';
    field %labels;
    field @fixups;

    method labels() { return \%labels; }
    method reg($r) {
        my $name = lc( $r // '' );
        die "Unknown RISC-V register: $r" unless exists $REG_MAP->{$name};
        return $REG_MAP->{$name};
    }

    method label($key) { $labels{$key} // () }
    method ret ()      { $code .= pack( 'L<', 0x00008067 ) }
    method append_code ($bin) { $code .= $bin }

    method push_reg($reg) {
        my $r = $self->reg($reg);
        $self->sub_imm( 'sp', 8 );
        $self->_sd( $r, 0, 2 ); # sd r, 0(sp)
    }

    method pop_reg($reg) {
        my $r = $self->reg($reg);
        $self->_ld( $r, 0, 2 ); # ld r, 0(sp)
        $self->add_imm( 'sp', 8 );
    }

    method ldxr_reg ( $t, $n ) {
        my $rt = $self->reg($t);
        my $rn = $self->reg($n);
        # lr.d rt, (rn)
        $code .= pack( 'L<', 0x0600302F | ( $rn << 15 ) | ( $rt << 7 ) );
    }

    method stxr_reg ( $s, $t, $n ) {
        my $rs = $self->reg($s);
        my $rt = $self->reg($t);
        my $rn = $self->reg($n);
        # sc.d rs, rt, (rn)
        $code .= pack( 'L<', 0x060030AF | ( $rn << 15 ) | ( $rt << 20 ) | ( $rs << 7 ) );
    }

    method sturb_mem_disp_reg( $base, $disp, $src ) {
        my $rb = $self->reg($base);
        my $rs = $self->reg($src);
        # sb rs, disp(rb)
        $code .= pack( 'L<', ( ( $disp & 0xFE0 ) << 20 ) | ( $rs << 20 ) | ( $rb << 15 ) | ( 0 << 12 ) | ( ( $disp & 0x1F ) << 7 ) | 0x23 );
    }

    method fmov_x_to_d ( $d, $s ) {
        my $rd = $self->reg($d);
        my $rs = $self->reg($s);
        # fmv.d.x rd, rs
        $code .= pack( 'L<', 0xF2200053 | ( $rs << 15 ) | ( $rd << 7 ) );
    }

    method fmov_d_to_x ( $d, $s ) {
        my $rd = $self->reg($d);
        my $rs = $self->reg($s);
        # fmv.x.d rd, rs
        $code .= pack( 'L<', 0xE2200053 | ( $rs << 15 ) | ( $rd << 7 ) );
    }

    method _lui ( $r, $imm20 ) {
        $code .= pack( 'L<', ( ( $imm20 & 0xFFFFF ) << 12 ) | ( $r << 7 ) | 0x37 );
    }

    method _addi ( $rd, $rs1, $imm12 ) {
        $code .= pack( 'L<', ( ( $imm12 & 0xFFF ) << 20 ) | ( $rs1 << 15 ) | ( $rd << 7 ) | 0x13 );
    }

    method _sub ( $rd, $rs1, $rs2 ) {
        $code .= pack( 'L<', ( 0x20 << 25 ) | ( $rs2 << 20 ) | ( $rs1 << 15 ) | ( $rd << 7 ) | 0x33 );
    }

    method _add ( $rd, $rs1, $rs2 ) {
        $code .= pack( 'L<', ( 0x00 << 25 ) | ( $rs2 << 20 ) | ( $rs1 << 15 ) | ( $rd << 7 ) | 0x33 );
    }

    method _mul ( $rd, $rs1, $rs2 ) {
        $code .= pack( 'L<', ( 0x01 << 25 ) | ( $rs2 << 20 ) | ( $rs1 << 15 ) | ( 0 << 12 ) | ( $rd << 7 ) | 0x33 );
    }

    method _ld ( $rd, $imm12, $rs1 ) {
        $code .= pack( 'L<', ( ( $imm12 & 0xFFF ) << 20 ) | ( $rs1 << 15 ) | ( 3 << 12 ) | ( $rd << 7 ) | 0x03 );
    }

    method _lb ( $rd, $imm12, $rs1 ) {
        $code .= pack( 'L<', ( ( $imm12 & 0xFFF ) << 20 ) | ( $rs1 << 15 ) | ( 0 << 12 ) | ( $rd << 7 ) | 0x03 );
    }

    method _lbu ( $rd, $imm12, $rs1 ) {
        $code .= pack( 'L<', ( ( $imm12 & 0xFFF ) << 20 ) | ( $rs1 << 15 ) | ( 4 << 12 ) | ( $rd << 7 ) | 0x03 );
    }

    method _sd ( $rs2, $imm12, $rs1 ) {
        my $hi = ( $imm12 >> 5 ) & 0x7F;
        my $lo = $imm12 & 0x1F;
        $code .= pack( 'L<', ( $hi << 25 ) | ( $rs2 << 20 ) | ( $rs1 << 15 ) | ( 3 << 12 ) | ( $lo << 7 ) | 0x23 );
    }

    method _sb ( $rs2, $imm12, $rs1 ) {
        my $hi = ( $imm12 >> 5 ) & 0x7F;
        my $lo = $imm12 & 0x1F;
        $code .= pack( 'L<', ( $hi << 25 ) | ( $rs2 << 20 ) | ( $rs1 << 15 ) | ( 0 << 12 ) | ( $lo << 7 ) | 0x23 );
    }

    method _srli ( $rd, $rs1, $shamt ) {
        $code .= pack( 'L<', ( 0x00 << 25 ) | ( ( $shamt & 0x3F ) << 20 ) | ( $rs1 << 15 ) | ( 5 << 12 ) | ( $rd << 7 ) | 0x13 );
    }

    method mov_imm ( $reg, $imm ) {
        my $r = $self->reg($reg);
        if ( $imm >= -2048 && $imm <= 2047 ) {
            $self->_addi( $r, 0, $imm );
        }
        else {
            my $upper = ( $imm + 0x800 ) >> 12;
            my $lower = $imm - ( $upper << 12 );
            $self->_lui( $r, $upper & 0xFFFFF );
            $self->_addi( $r, $r, $lower ) if $lower;
        }
    }

    method mov_reg ( $dest, $src ) {
        my $d = $self->reg($dest);
        my $s = $self->reg($src);
        $self->_addi( $d, $s, 0 );
    }

    method add_imm ( $reg, $imm ) {
        my $r = $self->reg($reg);
        $self->_addi( $r, $r, $imm );
    }

    method sub_imm ( $reg, $imm ) {
        my $r = $self->reg($reg);
        $self->_addi( $r, $r, -$imm );
    }

    method add_reg ( $d, $s1, $s2 = undef ) {
        my $rd  = $self->reg($d);
        my $rs1 = $self->reg($s1);
        my $rs2 = defined $s2 ? $self->reg($s2) : $rd;
        $self->_add( $rd, $rs1, $rs2 );
    }

    method sub_reg ( $d, $s1, $s2 = undef ) {
        my $rd  = $self->reg($d);
        my $rs1 = $self->reg($s1);
        my $rs2 = defined $s2 ? $self->reg($s2) : $rd;
        $self->_sub( $rd, $rs1, $rs2 );
    }

    method mul_reg ( $d, $s1, $s2 = undef ) {
        my $rd  = $self->reg($d);
        my $rs1 = $self->reg($s1);
        my $rs2 = defined $s2 ? $self->reg($s2) : $rd;
        $self->_mul( $rd, $rs1, $rs2 );
    }

    method lsr_reg_imm ( $d, $s, $amt ) {
        my $rd = $self->reg($d);
        my $rs = $self->reg($s);
        $self->_srli( $rd, $rs, $amt );
    }

    method load_reg_mem( $dest, $src, $disp = 0 ) {
        my $rd = $self->reg($dest);
        my $rs = $self->reg($src);
        $self->_ld( $rd, $disp, $rs );
    }

    method load_reg_mem_byte( $dest, $src, $disp = 0 ) {
        my $rd = $self->reg($dest);
        my $rs = $self->reg($src);
        $self->_lbu( $rd, $disp, $rs );
    }

    method store_mem_disp_reg( $base, $disp, $src ) {
        my $rb = $self->reg($base);
        my $rs = $self->reg($src);
        $self->_sd( $rs, $disp, $rb );
    }

    method store_mem_disp_byte( $base, $disp, $src ) {
        my $rb = $self->reg($base);
        my $rs = $self->reg($src);
        $self->_sb( $rs, $disp, $rb );
    }

    method cmp_reg_imm ( $reg, $imm ) {
        my $r = $self->reg($reg);
        my $t = 5; # t0
        $self->mov_imm( 't0', $imm );
        $self->_sub( $t, $r, $t );
    }

    method lea_rva ( $reg, $target_rva, $text_rva = 0 ) {
        my $r   = $self->reg($reg);
        my $off = ( $target_rva =~ /^\d+$/ ) ? $target_rva - ( $text_rva + length($code) ) : 0;
        $code .= pack( 'L<', ( ( ( $off + 0x800 ) >> 12 ) & 0xFFFFF ) << 12 | ( $r << 7 ) | 0x17 ); # AUIPC
        $self->_addi( $r, $r, $off & 0xFFF );
        push @fixups, { offset => length($code) - 8, target => $target_rva, type => 'pcrel' } if $target_rva !~ /^\d+$/;
    }

    method call_rva ( $target_rva, $text_rva ) {
        my $t = 5; # t0
        $self->lea_rva( 't0', $target_rva, $text_rva );
        $self->_ld( $t, 0, $t );
        $code .= pack( 'L<', ( $t << 15 ) | ( 1 << 7 ) | 0x67 ); # JALR ra, t0, 0
    }

    method call_label ($label) {
        push @fixups, { offset => length($code), target => $label, type => 'call' };
        $code .= pack( 'L<', 0x000000EF ); # JAL ra, 0
    }

    method syscall ( $os = '', $num = 0 ) {
        $code .= pack( 'L<', 0x00000073 );
    }

    method jcc ( $cc, $label ) {
        my $rs1    = 5; # t0
        my $rs2    = 0; # zero
        my $funct3 = 0;
        if    ( $cc == 0 || $cc == 4 ) { $funct3 = 0 } # BEQ
        elsif ( $cc == 1 || $cc == 5 ) { $funct3 = 1 } # BNE
        elsif ( $cc == 0xB )           { $funct3 = 4 } # BLT
        elsif ( $cc == 0xA )           { $funct3 = 5 } # BGE
        else                           { $funct3 = 0 }
        push @fixups, { offset => length($code), target => $label, type => 'branch', funct3 => $funct3, rs1 => $rs1, rs2 => $rs2 };
        $code .= pack( 'L<', 0 );
    }

    method jmp ($label) {
        push @fixups, { offset => length($code), target => $label, type => 'jal' };
        $code .= pack( 'L<', 0x0000006F ); # JAL zero, 0
    }

    method mark_label ($name) { $labels{$name} = length $code }

    method resolve ( $text_rva, $data_rva ) {
        for (@fixups) {
            my $target_off = $labels{ $_->{target} } // die "Undefined label: $_->{target}";
            my $off        = $target_off - $_->{offset};
            if ( $_->{type} eq 'jal' || $_->{type} eq 'call' ) {
                my $rd = ( $_->{type} eq 'call' ) ? 1 : 0;
                my $instr = 0x6F | ( $rd << 7 );
                $instr |= ( ( $off >> 20 ) & 1 ) << 31;
                $instr |= ( ( $off >> 1 ) & 0x3FF ) << 21;
                $instr |= ( ( $off >> 11 ) & 1 ) << 20;
                $instr |= ( ( $off >> 12 ) & 0xFF ) << 12;
                substr( $code, $_->{offset}, 4, pack( 'L<', $instr ) );
            }
            elsif ( $_->{type} eq 'branch' ) {
                my $instr = 0x63 | ( $_->{funct3} << 12 ) | ( $_->{rs1} << 15 ) | ( $_->{rs2} << 20 );
                $instr |= ( ( $off >> 12 ) & 1 ) << 31;
                $instr |= ( ( $off >> 5 ) & 0x3F ) << 25;
                $instr |= ( ( $off >> 1 ) & 0xF ) << 8;
                $instr |= ( ( $off >> 11 ) & 1 ) << 7;
                substr( $code, $_->{offset}, 4, pack( 'L<', $instr ) );
            }
        }
    }
}

1;
