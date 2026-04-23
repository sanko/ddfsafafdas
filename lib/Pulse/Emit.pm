package Pulse::Emit {
    use v5.40;
    use utf8;
    use feature 'class';
    no warnings 'portable', 'experimental::class';
    #
    class Pulse::Emit::ARM64 {
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
        method reg         ($r)   { $REG{ lc $r } // die "Unknown ARM64 register: $r" }
        method append_code ($bin) { $code .= $bin }

        method mov_imm ( $reg, $imm ) {
            my $r = $self->reg($reg);
            $code .= pack( 'L<', 0xD2800000 | ( ( $imm & 0xFFFF ) << 5 ) | $r );
            if ( ( $imm >> 16 ) & 0xFFFF ) { $code .= pack( 'L<', 0xF2A00000 | ( 1 << 21 ) | ( ( ( $imm >> 16 ) & 0xFFFF ) << 5 ) | $r ); }
            if ( ( $imm >> 32 ) & 0xFFFF ) { $code .= pack( 'L<', 0xF2C00000 | ( 2 << 21 ) | ( ( ( $imm >> 32 ) & 0xFFFF ) << 5 ) | $r ); }
        }
        method mov_reg ( $dest, $src ) { my $d = $self->reg($dest); my $s = $self->reg($src); $code .= pack( 'L<', 0xAA0003E0 | ( $s << 16 ) | $d ); }
        method add_imm ( $reg, $imm ) { my $r = $self->reg($reg); $code .= pack( 'L<', 0x91000000 | ( ( $imm & 0xFFF ) << 10 ) | ( $r << 5 ) | $r ); }
        method sub_imm ( $reg, $imm ) { my $r = $self->reg($reg); $code .= pack( 'L<', 0xD1000000 | ( ( $imm & 0xFFF ) << 10 ) | ( $r << 5 ) | $r ); }

        method add_reg ( $dest, $src ) {
            my $d = $self->reg($dest);
            my $s = $self->reg($src);
            $code .= pack( 'L<', 0x8B000000 | ( $s << 16 ) | ( $d << 5 ) | $d );
        }

        method sub_reg ( $dest, $src ) {
            my $d = $self->reg($dest);
            my $s = $self->reg($src);
            $code .= pack( 'L<', 0xCB000000 | ( $s << 16 ) | ( $d << 5 ) | $d );
        }

        method mul_reg ( $dest, $src ) {
            my $d = $self->reg($dest);
            my $s = $self->reg($src);
            $code .= pack( 'L<', 0x9B007C00 | ( $s << 16 ) | ( $d << 5 ) | $d );
        }    # madd d, d, s, xzr

        method cmp_reg_reg ( $left, $right ) {
            my $l = $self->reg($left);
            my $r = $self->reg($right);
            $code .= pack( 'L<', 0xEB000000 | ( $r << 16 ) | 31 | ( $l << 5 ) );
        }
        method setcc ( $cc, $dest ) { my $d = $self->reg($dest); my $inv_cc = $cc ^ 1; $code .= pack( 'L<', 0x9A9F03E0 | ( $inv_cc << 12 ) | $d ); }

        method test_reg_reg ( $left, $right ) {
            my $l = $self->reg($left);
            my $r = $self->reg($right);
            $code .= pack( 'L<', 0xEA000000 | ( $r << 16 ) | 31 | ( $l << 5 ) );
        }

        method load_reg_mem ( $dest, $src ) {
            my $d = $self->reg($dest);
            my $s = $self->reg($src);
            $code .= pack( 'L<', 0xF9400000 | ( $s << 5 ) | $d );
        }

        method lea_rva ( $reg, $target_rva, $text_rva ) {
            my $r     = $self->reg($reg);
            my $off   = $target_rva - ( $text_rva + length($code) );
            my $immlo = $off & 0x3;
            my $immhi = ( $off >> 2 ) & 0x7FFFF;
            $code .= pack( 'L<', 0x10000000 | ( $immlo << 29 ) | ( $immhi << 5 ) | $r );
        }

        method call_rva ( $target_rva, $text_rva ) {
            $self->lea_rva( 'x16', $target_rva, $text_rva );
            $code .= pack( 'L<', 0xF9400000 | ( 16 << 5 ) | 16 );
            $code .= pack( 'L<', 0xD63F0200 );
        }
        method call_label ($label) { push @fixups, { offset => length($code), target => $label, type => 'call' }; $code .= pack( 'L<', 0x94000000 ); }
        method syscall    ( $macos = 0 ) { $code .= pack( 'L<', $macos ? 0xD4001001 : 0xD4000001 ); }

        method jcc ( $cc, $label ) {
            push @fixups, { offset => length($code), target => $label, type => 'cond', cc => $cc };
            $code .= pack( 'L<', 0x54000000 | $cc );
        }
        method jmp ($label) { push @fixups, { offset => length($code), target => $label, type => 'uncond' }; $code .= pack( 'L<', 0x14000000 ); }
        method mark_label ($name) { $labels{$name} = length $code; }

        method resolve {
            for (@fixups) {
                my $target = $labels{ $_->{target} };
                my $off    = ( $target - $_->{offset} ) / 4;
                if ( $_->{type} eq 'cond' ) {
                    my $instr = unpack( 'L<', substr( $code, $_->{offset}, 4 ) );
                    $instr |= ( $off & 0x7FFFF ) << 5;
                    substr( $code, $_->{offset}, 4, pack( 'L<', $instr ) );
                }
                else {
                    my $instr = unpack( 'L<', substr( $code, $_->{offset}, 4 ) );
                    $instr |= ( $off & 0x3FFFFFF );
                    substr( $code, $_->{offset}, 4, pack( 'L<', $instr ) );
                }
            }
        }
    }

    class Pulse::Emit::X64 {
        our %REG = (
            rax => 0,
            rcx => 1,
            rdx => 2,
            rbx => 3,
            rsp => 4,
            rbp => 5,
            rsi => 6,
            rdi => 7,
            r8  => 8,
            r9  => 9,
            r10 => 10,
            r11 => 11,
            r12 => 12,
            r13 => 13,
            r14 => 14,
            r15 => 15
        );
        field $code : reader = '';
        field %labels;
        field @fixups;
        method reg         ($r)               { $REG{ lc $r } // die "Unknown X64 register: $r" }
        method append_code ($bin)             { $code .= $bin }
        method rex         ( $w, $r, $x, $b ) { $self->_rex( $w, $r, $x, $b ) }

        method _rex ( $w, $r, $x, $b ) {
            my $rex = 0x40;
            $rex |= 0x08 if $w;
            $rex |= 0x04 if $r >= 8;
            $rex |= 0x01 if $b >= 8;
            return ( $rex == 0x40 && !$w ) ? '' : pack( 'C', $rex );
        }
        method mov_imm ( $reg, $imm ) { my $r = $self->reg($reg); $code .= $self->_rex( 1, 0, 0, $r ) . pack( 'Cq<', 0xB8 + ( $r & 7 ), $imm ); }

        method mov_reg ( $dest, $src ) {
            my $d = $self->reg($dest);
            my $s = $self->reg($src);
            $code .= $self->_rex( 1, $s, 0, $d ) . pack( 'CC', 0x89, 0xC0 | ( ( $s & 7 ) << 3 ) | ( $d & 7 ) );
        }

        method add_imm ( $reg, $imm ) {
            my $r = $self->reg($reg);
            $code .= $self->_rex( 1, 0, 0, $r ) . pack( 'CCl<', 0x81, 0xC0 | ( $r & 7 ), $imm );
        }

        method sub_imm ( $reg, $imm ) {
            my $r = $self->reg($reg);
            $code .= $self->_rex( 1, 0, 0, $r ) . pack( 'CCl<', 0x81, 0xE8 | ( $r & 7 ), $imm );
        }

        method add_reg ( $dest, $src ) {
            my $d = $self->reg($dest);
            my $s = $self->reg($src);
            $code .= $self->_rex( 1, $s, 0, $d ) . pack( 'CC', 0x01, 0xC0 | ( ( $s & 7 ) << 3 ) | ( $d & 7 ) );
        }

        method sub_reg ( $dest, $src ) {
            my $d = $self->reg($dest);
            my $s = $self->reg($src);
            $code .= $self->_rex( 1, $s, 0, $d ) . pack( 'CC', 0x29, 0xC0 | ( ( $s & 7 ) << 3 ) | ( $d & 7 ) );
        }

        method mul_reg ( $dest, $src ) {
            my $d = $self->reg($dest);
            my $s = $self->reg($src);
            $code .= $self->_rex( 1, $d, 0, $s ) . pack( 'CCC', 0x0F, 0xAF, 0xC0 | ( ( $d & 7 ) << 3 ) | ( $s & 7 ) );
        }

        method cmp_reg_reg ( $left, $right ) {
            my $l = $self->reg($left);
            my $r = $self->reg($right);
            $code .= $self->_rex( 1, $r, 0, $l ) . pack( 'CC', 0x39, 0xC0 | ( ( $r & 7 ) << 3 ) | ( $l & 7 ) );
        }

        method setcc ( $cc, $dest ) {
            my $d = $self->reg($dest);
            $code .= pack( 'C', 0x40 | ( $d >= 8 ? 1 : 0 ) ) . pack( 'CCC', 0x0F, $cc, 0xC0 | ( $d & 7 ) );
        }

        method test_reg_reg ( $left, $right ) {
            my $l = $self->reg($left);
            my $r = $self->reg($right);
            $code .= $self->_rex( 1, $r, 0, $l ) . pack( 'CC', 0x85, 0xC0 | ( ( $r & 7 ) << 3 ) | ( $l & 7 ) );
        }

        method load_reg_mem ( $dest, $src ) {
            my $d = $self->reg($dest);
            my $s = $self->reg($src);
            $code .= $self->_rex( 1, $d, 0, $s ) . pack( 'CC', 0x8B, 0x40 | ( ( $d & 7 ) << 3 ) | ( $s & 7 ) );
            $code .= pack( 'C', 0x24 ) if ( $s & 7 ) == 4;
            $code .= pack( 'c', 0 );
        }

        method lea_reg_disp ( $dest, $base, $disp ) {
            my $d = $self->reg($dest);
            my $b = $self->reg($base);
            $code .= $self->_rex( 1, $d, 0, $b ) . pack( 'CC', 0x8D, 0x40 | ( ( $d & 7 ) << 3 ) | ( $b & 7 ) );
            $code .= pack( 'C', 0x24 ) if ( $b & 7 ) == 4;
            $code .= pack( 'c', $disp );
        }

        method store_mem_disp_reg ( $base, $disp, $src ) {
            my $b = $self->reg($base);
            my $s = $self->reg($src);
            $code .= $self->_rex( 1, $s, 0, $b ) . pack( 'CC', 0x89, 0x40 | ( ( $s & 7 ) << 3 ) | ( $b & 7 ) );
            $code .= pack( 'C', 0x24 ) if ( $b & 7 ) == 4;
            $code .= pack( 'c', $disp );
        }

        method lea_rva ( $reg, $target_rva, $text_rva ) {
            my $r        = $self->reg($reg);
            my $next_rip = $text_rva + length($code) + 7;
            $code .= $self->_rex( 1, $r, 0, 0 ) . pack( 'CC l<', 0x8D, 0x05 | ( ( $r & 7 ) << 3 ), $target_rva - $next_rip );
        }

        method call_rva ( $target_rva, $text_rva ) {
            my $next_rip = $text_rva + length($code) + 6;
            $code .= pack( 'CC l<', 0xFF, 0x15, $target_rva - $next_rip );
        }

        method call_label ($label) {
            $code .= pack( 'C', 0xE8 );
            push @fixups, { offset => length($code), target => $label };
            $code .= pack( 'L<', 0 );
        }
        method syscall { $code .= pack 'CC', 0x0F, 0x05 }

        method jcc ( $cc, $label ) {
            $code .= pack( 'CC', 0x0F, 0x80 + $cc );
            push @fixups, { offset => length($code), target => $label };
            $code .= pack( 'L<', 0 );
        }
        method jmp ($label) { $code .= pack( 'C', 0xE9 ); push @fixups, { offset => length($code), target => $label }; $code .= pack( 'L<', 0 ); }
        method mark_label ($name) { $labels{$name} = length $code; }

        method resolve {
            for (@fixups) {
                my $target = $labels{ $_->{target} };
                substr( $code, $_->{offset}, 4, pack( 'l<', $target - ( $_->{offset} + 4 ) ) );
            }
        }
    }
};
1;
