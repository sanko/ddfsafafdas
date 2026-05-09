package Brocken::Target::ARM64::Emit {
    use v5.40;
    use utf8;
    use feature 'class';
    no warnings 'portable', 'experimental::class';

    class Brocken::Target::ARM64::Emit {
        our %REG = (
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
            xzr => 31
        );
        field $code : reader = '';
        field %labels;
        field @fixups;
        method reg($r)                { $REG{ lc $r } // die 'Unknown ARM64 register: ' . $r }
        method append_code($bin)      { $code .= $bin }

        method push_reg($reg) {
            my $r = $self->reg($reg);

            # STR Rt, [SP, #-16]!  (Pre-indexed with writeback)
            $code .= pack( 'L<', 0xF81F0FE0 | $r );
        }

        method pop_reg($reg) {
            my $r = $self->reg($reg);

            # LDR Rt, [SP], #16    (Post-indexed)
            $code .= pack( 'L<', 0xF84107E0 | $r );
        }

        method push_imm($imm) { $self->mov_imm( 'x16', $imm ); $self->push_reg('x16'); }

        method mov_imm( $r, $imm ) {
            my $ri = $self->reg($r);
            my $v  = $imm;
            if ( $v >= 0 && $v <= 0xFFFF ) {
                $code .= pack( 'L<', 0xD2800000 | ( ( $v & 0xFFFF ) << 5 ) | $ri );
            }
            else {
                my $first = 1;
                for my $hw ( 0 .. 3 ) {
                    my $chunk = ( $v >> ( $hw * 16 ) ) & 0xFFFF;
                    if ($first) {
                        $code .= pack( 'L<', 0xD2800000 | ( $hw << 21 ) | ( $chunk << 5 ) | $ri );
                        $first = 0;
                    }
                    elsif ( $chunk != 0 ) {
                        $code .= pack( 'L<', 0xF2800000 | ( $hw << 21 ) | ( $chunk << 5 ) | $ri );
                    }
                }
                if ($first) { $code .= pack( 'L<', 0xD2800000 | $ri ); }
            }
        }

        method mov_reg( $dest, $src ) {
            my $d = $self->reg($dest);
            my $s = $self->reg($src);

            if ( $dest eq 'sp' || $src eq 'sp' ) {
                $code .= pack( 'L<', 0x91000000 | ( $s << 5 ) | $d );
            }
            else {
                $code .= pack( 'L<', 0xAA0003E0 | ( $s << 16 ) | $d );
            }
        }

        method add_imm( $reg, $imm ) {
            my $r = $self->reg($reg);
            $code .= pack( 'L<', 0x91000000 | ( ( $imm & 0xFFF ) << 10 ) | ( $r << 5 ) | $r );
        }

        method sub_imm( $reg, $imm ) {
            my $r = $self->reg($reg);
            $code .= pack( 'L<', 0xD1000000 | ( ( $imm & 0xFFF ) << 10 ) | ( $r << 5 ) | $r );
        }

        method add_reg( $dest, $rn, $rm ) {
            my $d = $self->reg($dest);
            my $n = $self->reg($rn);
            my $m = $self->reg($rm);
            $code .= pack( 'L<', 0x8B000000 | ( $m << 16 ) | ( $n << 5 ) | $d );
        }

        method sub_reg( $dest, $rn, $rm ) {
            my $d = $self->reg($dest);
            my $n = $self->reg($rn);
            my $m = $self->reg($rm);
            $code .= pack( 'L<', 0xCB000000 | ( $m << 16 ) | ( $n << 5 ) | $d );
        }

        method mul_reg( $dest, $rn, $rm ) {
            my $d = $self->reg($dest);
            my $n = $self->reg($rn);
            my $m = $self->reg($rm);
            $code .= pack( 'L<', 0x9B007C00 | ( $m << 16 ) | ( $n << 5 ) | $d );
        }

        method msub_reg( $dest, $rn, $rm, $ra ) {
            my $d = $self->reg($dest);
            my $n = $self->reg($rn);
            my $m = $self->reg($rm);
            my $a = $self->reg($ra);
            $code .= pack( 'L<', 0x9B008000 | ( $m << 16 ) | ( $a << 10 ) | ( $n << 5 ) | $d );
        }

        method cmp_reg_reg( $l, $r ) {
            my $ld = $self->reg($l);
            my $rd = $self->reg($r);
            $code .= pack( 'L<', 0xEB000000 | ( $rd << 16 ) | 31 | ( $ld << 5 ) );
        }

        method cmp_reg_imm( $reg, $imm ) {
            my $r = $self->reg($reg);
            $code .= pack( 'L<', 0xF1000000 | ( ( $imm & 0xFFF ) << 10 ) | ( $r << 5 ) | 31 );
        }

        method sdiv_reg( $dest, $rn, $rm ) {
            my $d = $self->reg($dest);
            my $n = $self->reg($rn);
            my $m = $self->reg($rm);
            $code .= pack( 'L<', 0x9AC00800 | ( $m << 16 ) | ( $n << 5 ) | $d );
        }

        method lsl_imm( $dest, $src, $amt ) {
            my $d = $self->reg($dest);
            my $s = $self->reg($src);
            $amt &= 0x3F;
            my $immr = ( -$amt ) & 0x3F;
            my $imms = 63 - $amt;
            $code .= pack( 'L<', 0xD3400000 | ( $immr << 16 ) | ( $imms << 10 ) | ( $s << 5 ) | $d );
        }

        method lsr_imm( $dest, $src, $amt ) {
            my $d = $self->reg($dest);
            my $s = $self->reg($src);
            $amt &= 0x3F;
            $code .= pack( 'L<', 0xD340FC00 | ( $amt << 16 ) | ( $s << 5 ) | $d );
        }

        method lsl_reg( $dest, $src, $amt ) {
            my $d = $self->reg($dest);
            my $s = $self->reg($src);
            my $a = $self->reg($amt);
            $code .= pack( 'L<', 0x9AC02000 | ( $a << 16 ) | ( $s << 5 ) | $d );
        }

        method lsr_reg( $dest, $src, $amt ) {
            my $d = $self->reg($dest);
            my $s = $self->reg($src);
            my $a = $self->reg($amt);
            $code .= pack( 'L<', 0x9AC02400 | ( $a << 16 ) | ( $s << 5 ) | $d );
        }

        method and_reg( $dest, $rn, $rm ) {
            my $d = $self->reg($dest);
            my $n = $self->reg($rn);
            my $m = $self->reg($rm);
            $code .= pack( 'L<', 0x8A000000 | ( $m << 16 ) | ( $n << 5 ) | $d );
        }

        method or_reg( $dest, $rn, $rm ) {
            my $d = $self->reg($dest);
            my $n = $self->reg($rn);
            my $m = $self->reg($rm);
            $code .= pack( 'L<', 0xAA000000 | ( $m << 16 ) | ( $n << 5 ) | $d );
        }

        method xor_reg( $dest, $rn, $rm ) {
            my $d = $self->reg($dest);
            my $n = $self->reg($rn);
            my $m = $self->reg($rm);
            $code .= pack( 'L<', 0xCA000000 | ( $m << 16 ) | ( $n << 5 ) | $d );
        }

        method setcc( $cc, $r ) {
            my $ri = $self->reg($r);
            my $inv_cc = $cc ^ 1;
            $code .= pack( 'L<', 0x9A9F07E0 | ( $inv_cc << 12 ) | $ri );
        }

        method test_reg_reg( $l, $r ) {
            my $ld = $self->reg($l);
            my $rd = $self->reg($r);
            $code .= pack( 'L<', 0xEA000000 | ( $rd << 16 ) | ( $ld << 5 ) | 31 );
        }

        method load_reg_mem( $dest, $src, $disp = 0 ) {
            my $d = $self->reg($dest);
            my $s = $self->reg($src);
            $code .= pack( 'L<', 0xF9400000 | ( ( ( $disp >> 3 ) & 0xFFF ) << 10 ) | ( $s << 5 ) | $d );
        }

        method store_mem_disp_reg( $base, $disp, $src ) {
            my $b = $self->reg($base);
            my $s = $self->reg($src);
            $code .= pack( 'L<', 0xF9000000 | ( ( ( $disp >> 3 ) & 0xFFF ) << 10 ) | ( $b << 5 ) | $s );
        }

        method load_reg_mem_byte( $dest, $src, $disp = 0 ) {
            my $d = $self->reg($dest);
            my $s = $self->reg($src);
            $code .= pack( 'L<', 0x39400000 | ( ( $disp & 0xFFF ) << 10 ) | ( $s << 5 ) | $d );
        }

        method store_mem_disp_byte( $base, $disp, $src ) {
            my $b = $self->reg($base);
            my $s = $self->reg($src);
            $code .= pack( 'L<', 0x39000000 | ( ( $disp & 0xFFF ) << 10 ) | ( $b << 5 ) | $s );
        }

        method ldur_reg_mem( $dest, $src, $disp = 0 ) {
            my $d = $self->reg($dest);
            my $s = $self->reg($src);
            $code .= pack( 'L<', 0xF8400000 | ( ( $disp & 0x1FF ) << 12 ) | ( $s << 5 ) | $d );
        }

        method stur_mem_disp_reg( $base, $disp, $src ) {
            my $b = $self->reg($base);
            my $s = $self->reg($src);
            $code .= pack( 'L<', 0xF8000000 | ( ( $disp & 0x1FF ) << 12 ) | ( $b << 5 ) | $s );
        }

        method ldurb_reg_mem( $dest, $src, $disp = 0 ) {
            my $d = $self->reg($dest);
            my $s = $self->reg($src);
            $code .= pack( 'L<', 0x38400000 | ( ( $disp & 0x1FF ) << 12 ) | ( $s << 5 ) | $d );
        }

        method sturb_mem_disp_reg( $base, $disp, $src ) {
            my $b = $self->reg($base);
            my $s = $self->reg($src);
            $code .= pack( 'L<', 0x38000000 | ( ( $disp & 0x1FF ) << 12 ) | ( $b << 5 ) | $s );
        }

        method lea_rva( $reg, $target, $txtrva = 0 ) {
            my $r = $self->reg($reg);
            if ( !defined $target ) { die "lea_rva: target is undefined" }
            if ( $target =~ /^[A-Z_]/i ) {
                push @fixups, { offset => length($code), target => $target, type => 'adr' };
                $code .= pack( 'L<', 0x10000000 | $r );
            }
            else {
                my $off = $target - ( $txtrva + length($code) );
                my $lo  = $off & 0x3;
                my $hi  = ( $off >> 2 ) & 0x7FFFF;
                $code .= pack( 'L<', 0x10000000 | ( $lo << 29 ) | ( $hi << 5 ) | $r );
            }
        }

        method call_label($l)    { push @fixups, { offset => length($code), target => $l, type => 'call' }; $code .= pack( 'L<', 0x94000000 ) }
        method syscall( $m = 0 ) { $code .= pack( 'L<', $m ? 0xD4001001 : 0xD4000001 ) }

        method jcc( $cc, $l ) {
            push @fixups, { offset => length($code), target => $l, type => 'cond', cc => $cc };
            $code .= pack( 'L<', 0x54000000 | $cc );
        }

        method jmp($l) { push @fixups, { offset => length($code), target => $l, type => 'uncond' }; $code .= pack( 'L<', 0x14000000 ) }

        method mark_label($n) { $labels{$n} = length $code }

        method resolve {
            for (@fixups) {
                my $t = $labels{ $_->{target} };
                die "Linker Error: Unresolved label '$_->{target}'\n" unless defined $t;
                my $off   = ( $t - $_->{offset} );
                my $instr = unpack( 'L<', substr( $code, $_->{offset}, 4 ) );
                if ( $_->{type} eq 'cond' ) {
                    my $woff = $off / 4;
                    $instr |= ( $woff & 0x7FFFF ) << 5;
                }
                elsif ( $_->{type} eq 'call' || $_->{type} eq 'uncond' ) {
                    my $woff = $off / 4;
                    $instr |= ( $woff & 0x3FFFFFF );
                }
                elsif ( $_->{type} eq 'adr' ) {
                    my $lo = $off & 0x3;
                    my $hi = ( $off >> 2 ) & 0x7FFFF;
                    $instr |= ( $lo << 29 ) | ( $hi << 5 );
                }
                substr( $code, $_->{offset}, 4, pack( 'L<', $instr ) );
            }
        }

        method call_rva( $trva, $txtrva ) {
            my $off = ( $trva - ( $txtrva + length($code) ) ) / 4;
            $code .= pack( 'L<', 0x94000000 | ( $off & 0x3FFFFFF ) );
        }
    }
}
1;
