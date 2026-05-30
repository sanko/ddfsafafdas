use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';

class Brocken::Target::Architecture::ARM64 : isa(Brocken::Target) {

    method registers() {
        return [qw(x19 x20 x21 x22 x23 x24 x25 x26 x27)];
    }

    method fp_registers() {
        return [qw(d8 d9 d10 d11 d12 d13 d14 d15)];
    }

    method _abi_arg_reg($idx) {
        return (qw[x0 x1 x2 x3 x4 x5 x6 x7])[$idx] // $idx;
    }

    method _abi_fp_arg_reg($idx) {
        return (qw[d0 d1 d2 d3 d4 d5 d6 d7])[$idx] // "d$idx";
    }

    method _abi_fp_return_reg() {
        return 'd0';
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
        return Brocken::Target::Architecture::ARM64::Emit->new();
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

class Brocken::Target::Architecture::ARM64::Emit {
    state $REG_MAP = {
        x0  => 0,
        x1  => 1,
        x2  => 2,
        x3  => 3,
        x4  => 4,
        x5  => 5,
        x6  => 6,
        x7  => 7,
        x8  => 8,
        x9  => 9,
        x10 => 10,
        x11 => 11,
        x12 => 12,
        x13 => 13,
        x14 => 14,
        x15 => 15,
        x16 => 16,
        x17 => 17,
        x18 => 18,
        x19 => 19,
        x20 => 20,
        x21 => 21,
        x22 => 22,
        x23 => 23,
        x24 => 24,
        x25 => 25,
        x26 => 26,
        x27 => 27,
        x28 => 28,
        x29 => 29,
        x30 => 30,
        sp  => 31,
        xzr => 31,
        rsp => 31,
        d0  => 0,
        d1  => 1,
        d2  => 2,
        d3  => 3,
        d4  => 4,
        d5  => 5,
        d6  => 6,
        d7  => 7,
        d8  => 8,
        d9  => 9,
        d10 => 10,
        d11 => 11,
        d12 => 12,
        d13 => 13,
        d14 => 14,
        d15 => 15,
        rax => 0,
        rcx => 1,
        rdx => 2,
        rbx => 3,
        rsi => 6,
        rdi => 7,
        r8  => 8,
        r9  => 9,
        r10 => 10,
        r11 => 11,
        r14 => 28
    };
    field $code : reader = '';
    field %labels;
    field @fixups;
    method labels() { return \%labels; }

    method reg($r) {
        my $name = lc( $r // '' );
        die "Unknown ARM64 register: $r" unless exists $REG_MAP->{$name};
        return $REG_MAP->{$name};
    }
    method label($key)        { $labels{$key} // () }
    method ret ()             { $code .= pack( 'L<', 0xD65F03C0 ) }
    method append_code ($bin) { $code .= $bin }

    method mov_imm ( $reg, $imm ) {
        my $r = $self->reg($reg);
        $code .= pack( 'L<', 0xD2800000 | ( ( $imm & 0xFFFF ) << 5 ) | $r );
        if ( ( $imm >> 16 ) & 0xFFFF ) {
            $code .= pack( 'L<', 0xF2A00000 | ( 1 << 21 ) | ( ( ( $imm >> 16 ) & 0xFFFF ) << 5 ) | $r );
        }
        if ( ( $imm >> 32 ) & 0xFFFF ) {
            $code .= pack( 'L<', 0xF2C00000 | ( 2 << 21 ) | ( ( ( $imm >> 32 ) & 0xFFFF ) << 5 ) | $r );
        }
        if ( ( $imm >> 48 ) & 0xFFFF ) {
            $code .= pack( 'L<', 0xF2E00000 | ( 3 << 21 ) | ( ( ( $imm >> 48 ) & 0xFFFF ) << 5 ) | $r );
        }
    }

    method mov_reg ( $dest, $src ) {
        my $d = $self->reg($dest);
        my $s = $self->reg($src);
        $code .= pack( 'L<', 0xAA0003E0 | ( $s << 16 ) | $d );
    }
    method push_reg($reg) { my $r = $self->reg($reg); $code .= pack( 'L<', 0xF81F0FE0 | $r ); }
    method pop_reg($reg)  { my $r = $self->reg($reg); $code .= pack( 'L<', 0xF84107E0 | $r ); }

    method add_imm ( $reg, $imm ) {
        my $r = $self->reg($reg);
        $code .= pack( 'L<', 0x91000000 | ( ( $imm & 0xFFF ) << 10 ) | ( $r << 5 ) | $r );
    }

    method sub_imm ( $reg, $imm ) {
        my $r = $self->reg($reg);
        $code .= pack( 'L<', 0xD1000000 | ( ( $imm & 0xFFF ) << 10 ) | ( $r << 5 ) | $r );
    }

    method add_reg ( $d, $s1, $s2 = undef ) {
        my $rd  = $self->reg($d);
        my $rs1 = $self->reg($s1);
        my $rs2 = defined $s2 ? $self->reg($s2) : $rd;
        $code .= pack( 'L<', 0x8B000000 | ( $rs2 << 16 ) | ( $rs1 << 5 ) | $rd );
    }

    method sub_reg ( $d, $s1, $s2 = undef ) {
        my $rd  = $self->reg($d);
        my $rs1 = $self->reg($s1);
        my $rs2 = defined $s2 ? $self->reg($s2) : $rd;
        $code .= pack( 'L<', 0xCB000000 | ( $rs2 << 16 ) | ( $rs1 << 5 ) | $rd );
    }

    method mul_reg ( $d, $s1, $s2 = undef ) {
        my $rd  = $self->reg($d);
        my $rs1 = $self->reg($s1);
        my $rs2 = defined $s2 ? $self->reg($s2) : $rd;
        $code .= pack( 'L<', 0x9B007C00 | ( $rs2 << 16 ) | ( $rs1 << 5 ) | $rd );
    }

    method sdiv_reg ( $d, $s1, $s2 = undef ) {
        my $rd  = $self->reg($d);
        my $rs1 = $self->reg($s1);
        my $rs2 = defined $s2 ? $self->reg($s2) : $rd;
        $code .= pack( 'L<', 0x9AC00C00 | ( $rs2 << 16 ) | ( $rs1 << 5 ) | $rd );
    }

    method and_reg ( $d, $s1, $s2 = undef ) {
        my $rd  = $self->reg($d);
        my $rs1 = $self->reg($s1);
        my $rs2 = defined $s2 ? $self->reg($s2) : $rd;
        $code .= pack( 'L<', 0x8A000000 | ( $rs2 << 16 ) | ( $rs1 << 5 ) | $rd );
    }

    method or_reg ( $d, $s1, $s2 = undef ) {
        my $rd  = $self->reg($d);
        my $rs1 = $self->reg($s1);
        my $rs2 = defined $s2 ? $self->reg($s2) : $rd;
        $code .= pack( 'L<', 0xAA000000 | ( $rs2 << 16 ) | ( $rs1 << 5 ) | $rd );
    }

    method xor_reg ( $d, $s1, $s2 = undef ) {
        my $rd  = $self->reg($d);
        my $rs1 = $self->reg($s1);
        my $rs2 = defined $s2 ? $self->reg($s2) : $rd;
        $code .= pack( 'L<', 0xCA000000 | ( $rs2 << 16 ) | ( $rs1 << 5 ) | $rd );
    }

    method lsl_imm ( $d, $s, $amt ) {
        my $rd = $self->reg($d);
        my $rs = $self->reg($s);
        $code .= pack( 'L<', 0xD3400000 | ( ( 64 - $amt ) << 16 ) | ( ( 63 - $amt ) << 10 ) | ( $rs << 5 ) | $rd );
    }

    method lsr_imm ( $d, $s, $amt ) {
        my $rd = $self->reg($d);
        my $rs = $self->reg($s);
        $code .= pack( 'L<', 0xD3400000 | ( $amt << 16 ) | ( 63 << 10 ) | ( $rs << 5 ) | $rd );
    }

    method shr_imm ( $d, $s, $amt = undef ) {
        if ( !defined $amt ) { $amt = $s; $s = $d }
        $self->lsr_imm( $d, $s, $amt );
    }
    method lsr_reg_imm ( $d, $s, $amt ) { $self->lsr_imm( $d, $s, $amt ) }

    method cmp_reg_imm ( $reg, $imm ) {
        my $r = $self->reg($reg);
        $code .= pack( 'L<', 0xF1000000 | ( ( $imm & 0xFFF ) << 10 ) | ( $r << 5 ) | 31 );
    }
    method cmp_reg_imm_32 ( $r, $imm ) { $self->cmp_reg_imm( $r, $imm ) }

    method cmp_reg_reg ( $l, $r ) {
        my $rl = $self->reg($l);
        my $rr = $self->reg($r);
        $code .= pack( 'L<', 0xEB000000 | ( $rr << 16 ) | ( $rl << 5 ) | 31 );
    }

    method test_reg_reg ( $l, $r ) {
        my $rl = $self->reg($l);
        my $rr = $self->reg($r);
        $code .= pack( 'L<', 0xEA000000 | ( $rr << 16 ) | ( $rl << 5 ) | 31 );
    }

    method setcc ( $cc, $r ) {
        my $ri = $self->reg($r);
        $code .= pack( 'L<', 0x1A9F07E0 | ( $cc << 12 ) | $ri );
    }

    method load_reg_mem( $dest, $src, $disp = 0 ) {
        my $d = $self->reg($dest);
        my $s = $self->reg($src);
        $code .= pack( 'L<', 0xF9400000 | ( ( $disp >> 3 ) << 10 ) | ( $s << 5 ) | $d );
    }

    method ldur_reg_mem( $dest, $src, $disp = 0 ) {
        my $d = $self->reg($dest);
        my $s = $self->reg($src);
        $code .= pack( 'L<', 0xF8400000 | ( ( $disp & 0x1FF ) << 12 ) | ( $s << 5 ) | $d );
    }

    method ldxr_reg ( $t, $n ) {
        my $rt = $self->reg($t);
        my $rn = $self->reg($n);
        $code .= pack( 'L<', 0xC85F7C00 | ( $rn << 5 ) | $rt );
    }

    method stxr_reg ( $s, $t, $n ) {
        my $rs = $self->reg($s);
        my $rt = $self->reg($t);
        my $rn = $self->reg($n);
        $code .= pack( 'L<', 0xC8007C00 | ( $rn << 5 ) | ( $rs << 16 ) | $rt );
    }

    method load_reg_mem_byte( $dest, $src, $disp = 0 ) {
        my $d = $self->reg($dest);
        my $s = $self->reg($src);
        $code .= pack( 'L<', 0x39400000 | ( $disp << 10 ) | ( $s << 5 ) | $d );
    }

    method store_mem_disp_reg( $base, $disp, $src ) {
        my $b = $self->reg($base);
        my $s = $self->reg($src);
        $code .= pack( 'L<', 0xF9000000 | ( ( $disp >> 3 ) << 10 ) | ( $b << 5 ) | $s );
    }

    method stur_mem_disp_reg( $base, $disp, $src ) {
        my $b = $self->reg($base);
        my $s = $self->reg($src);
        $code .= pack( 'L<', 0xF8000000 | ( ( $disp & 0x1FF ) << 12 ) | ( $b << 5 ) | $s );
    }

    method sturb_mem_disp_reg( $base, $disp, $src ) {
        my $b = $self->reg($base);
        my $s = $self->reg($src);
        $code .= pack( 'L<', 0x38000000 | ( ( $disp & 0x1FF ) << 12 ) | ( $b << 5 ) | $s );
    }

    method store_mem_disp_byte( $base, $disp, $src ) {
        my $b = $self->reg($base);
        my $s = $self->reg($src);
        $code .= pack( 'L<', 0x39000000 | ( $disp << 10 ) | ( $b << 5 ) | $s );
    }

    method lea_reg_disp ( $d, $b, $disp ) {
        my $rd = $self->reg($d);
        my $rb = $self->reg($b);
        $code .= pack( 'L<', 0x91000000 | ( ( $disp & 0xFFF ) << 10 ) | ( $rb << 5 ) | $rd );
    }

    method lea_rva ( $reg, $target_rva, $text_rva = 0 ) {
        my $r = $self->reg($reg);
        if ( $target_rva =~ /^DATA:(\d+)$/ ) {
            push @fixups, { offset => length($code), target => $1, type => 'adrp_data', reg => $r };
            $code .= pack( 'L<', 0x90000000 | $r );
            $code .= pack( 'L<', 0x91000000 | ( $r << 5 ) | $r );
            return;
        }
        my $off = ( $target_rva =~ /^\d+$/ ) ? $target_rva - ( $text_rva + length($code) ) : 0;
        push @fixups, { offset => length($code), target => $target_rva, type => 'adr', reg => $r } if $target_rva !~ /^\d+$/;
        my $immlo = $off & 0x3;
        my $immhi = ( $off >> 2 ) & 0x7FFFF;
        $code .= pack( 'L<', 0x10000000 | ( $immlo << 29 ) | ( $immhi << 5 ) | $r );
    }

    method call_rva ( $target_rva, $text_rva ) {
        $self->lea_rva( 'x16', $target_rva, $text_rva );
        $code .= pack( 'L<', 0xF9400000 | ( 16 << 5 ) | 16 );
        $code .= pack( 'L<', 0xD63F0200 );
    }

    method call_label ($label) {
        push @fixups, { offset => length($code), target => $label, type => 'call' };
        $code .= pack( 'L<', 0x94000000 );
    }

    method cbnz_label ( $reg, $label ) {
        my $ri = $self->reg($reg);
        push @fixups, { offset => length($code), target => $label, type => 'cbnz', reg => $ri };
        $code .= pack( 'L<', 0xB5000000 | $ri );
    }

    method syscall( $os = '', $num = 0 ) {
        if    ( $os eq 'macos' )              { $code .= pack( 'L<', 0xD4001001 ) }
        elsif ( $os eq 'netbsd' && $num > 0 ) { $code .= pack( 'L<', 0xD4000001 | ( ( $num & 0xFFFF ) << 5 ) ) }
        else {
            $code .= pack( 'L<', 0xD4000001 );
            if ( $os eq 'openbsd' ) { $code .= pack( 'L<', 0x14000002 ) . pack( 'L<', 0xD4200000 ) }
        }
    }

    method jcc ( $cc, $label ) {
        push @fixups, { offset => length($code), target => $label, type => 'cond', cc => $cc };
        $code .= pack( 'L<', 0x54000000 | $cc );
    }

    method jmp ($label) {
        push @fixups, { offset => length($code), target => $label, type => 'uncond' };
        $code .= pack( 'L<', 0x14000000 );
    }
    method mark_label ($name) { $labels{$name} = length $code }

    method fadd_reg ( $d, $s1, $s2 ) {
        my ( $rd, $rs1, $rs2 ) = ( $self->reg($d), $self->reg($s1), $self->reg($s2) );
        $code .= pack( 'L<', 0x1E602800 | ( $rs2 << 16 ) | ( $rs1 << 5 ) | $rd );
    }

    method fsub_reg ( $d, $s1, $s2 ) {
        my ( $rd, $rs1, $rs2 ) = ( $self->reg($d), $self->reg($s1), $self->reg($s2) );
        $code .= pack( 'L<', 0x1E603800 | ( $rs2 << 16 ) | ( $rs1 << 5 ) | $rd );
    }

    method fmul_reg ( $d, $s1, $s2 ) {
        my ( $rd, $rs1, $rs2 ) = ( $self->reg($d), $self->reg($s1), $self->reg($s2) );
        $code .= pack( 'L<', 0x1E600800 | ( $rs2 << 16 ) | ( $rs1 << 5 ) | $rd );
    }

    method fmov_reg ( $d, $s ) {
        my ( $rd, $rs ) = ( $self->reg($d), $self->reg($s) );
        $code .= pack( 'L<', 0x1E604000 | ( $rs << 5 ) | $rd );
    }

    method fcmp_reg ( $l, $r ) {
        my ( $rl, $rr ) = ( $self->reg($l), $self->reg($r) );
        $code .= pack( 'L<', 0x1E602000 | ( $rr << 16 ) | ( $rl << 5 ) );
    }

    method fmov_x_to_d ( $d, $s ) {
        my ( $rd, $rs ) = ( $self->reg($d), $self->reg($s) );
        $code .= pack( 'L<', 0x9E670000 | ( $rs << 5 ) | $rd );
    }

    method fmov_d_to_x ( $d, $s ) {
        my ( $rd, $rs ) = ( $self->reg($d), $self->reg($s) );
        $code .= pack( 'L<', 0x9E660000 | ( $rs << 5 ) | $rd );
    }

    method ldr_d_mem ( $d, $s, $off ) {
        my ( $rd, $rs ) = ( $self->reg($d), $self->reg($s) );
        $code .= pack( 'L<', 0xFD400000 | ( ( $off >> 3 ) << 10 ) | ( $rs << 5 ) | $rd );
    }

    method str_d_mem ( $d, $s, $off ) {
        my ( $rd, $rs ) = ( $self->reg($d), $self->reg($s) );
        $code .= pack( 'L<', 0xFD000000 | ( ( $off >> 3 ) << 10 ) | ( $rs << 5 ) | $rd );
    }

    method resolve ( $text_rva, $data_rva ) {
        for (@fixups) {
            my $target_off;
            if ( $_->{type} ne 'adrp_data' ) {
                $target_off = $labels{ $_->{target} }
                    // ( ( $_->{type} eq 'adr' && $_->{target} =~ /^\d+$/ ) ? undef : die "Undefined label: $_->{target}" );
            }
            if ( $_->{type} eq 'cond' ) {
                my $off   = ( $target_off - $_->{offset} ) / 4;
                my $instr = unpack( 'L<', substr( $code, $_->{offset}, 4 ) );
                $instr |= ( $off & 0x7FFFF ) << 5;
                substr( $code, $_->{offset}, 4, pack( 'L<', $instr ) );
            }
            elsif ( $_->{type} eq 'call' || $_->{type} eq 'uncond' ) {
                my $off   = ( $target_off - $_->{offset} ) / 4;
                my $instr = unpack( 'L<', substr( $code, $_->{offset}, 4 ) );
                $instr |= ( $off & 0x3FFFFFF );
                substr( $code, $_->{offset}, 4, pack( 'L<', $instr ) );
            }
            elsif ( $_->{type} eq 'cbnz' ) {
                my $off   = ( $target_off - $_->{offset} ) / 4;
                my $instr = unpack( 'L<', substr( $code, $_->{offset}, 4 ) );
                $instr |= ( $off & 0x7FFFF ) << 5;
                substr( $code, $_->{offset}, 4, pack( 'L<', $instr ) );
            }
            elsif ( $_->{type} eq 'adr' ) {
                my $off   = ( $target_off - $_->{offset} );
                my $instr = unpack( 'L<', substr( $code, $_->{offset}, 4 ) );
                $instr |= ( ( $off & 0x3 ) << 29 ) | ( ( ( $off >> 2 ) & 0x7FFFF ) << 5 );
                substr( $code, $_->{offset}, 4, pack( 'L<', $instr ) );
            }
            elsif ( $_->{type} eq 'adrp_data' ) {
                my $trva   = $data_rva + $_->{target};
                my $pc     = $text_rva + $_->{offset};
                my $p_diff = ( $trva & ~0xFFF ) - ( $pc & ~0xFFF );
                my $imm    = $p_diff >> 12;
                my $instr  = unpack( 'L<', substr( $code, $_->{offset}, 4 ) );
                $instr |= ( ( $imm & 0x3 ) << 29 ) | ( ( $imm & 0x1FFFFC ) << 3 );
                substr( $code, $_->{offset}, 4, pack( 'L<', $instr ) );
                my $instr2 = unpack( 'L<', substr( $code, $_->{offset} + 4, 4 ) );
                $instr2 |= ( $trva & 0xFFF ) << 10;
                substr( $code, $_->{offset} + 4, 4, pack( 'L<', $instr2 ) );
            }
        }
    }
}
1;
