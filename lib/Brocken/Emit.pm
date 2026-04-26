package Brocken::Emit {
    use v5.40;
    use utf8;
    use feature 'class';
    no warnings 'portable', 'experimental::class';

    class Brocken::Emit::ARM64 {
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
        method push_reg($reg)         { my $r = $self->reg($reg); $code .= pack( 'L<', 0xF81F0FE0 | $r ); }
        method pop_reg($reg)          { my $r = $self->reg($reg); $code .= pack( 'L<', 0xF84107E0 | $r ); }
        method push_imm($imm)         { $self->mov_imm( 'x16', $imm ); $self->push_reg('x16'); }
        method mov_imm( $r, $imm )    { my $ri = $self->reg($r);    $code .= pack( 'L<', 0xD2800000 | ( ( $imm & 0xFFFF ) << 5 ) | $ri ); }
        method mov_reg( $dest, $src ) { my $d  = $self->reg($dest); my $s = $self->reg($src); $code .= pack( 'L<', 0xAA0003E0 | ( $s << 16 ) | $d ) }
        method add_imm( $reg, $imm )  { my $r  = $self->reg($reg); $code .= pack( 'L<', 0x91000000 | ( ( $imm & 0xFFF ) << 10 ) | ( $r << 5 ) | $r ) }
        method sub_imm( $reg, $imm )  { my $r  = $self->reg($reg); $code .= pack( 'L<', 0xD1000000 | ( ( $imm & 0xFFF ) << 10 ) | ( $r << 5 ) | $r ) }

        method add_reg( $dest, $src ) {
            my $d = $self->reg($dest);
            my $s = $self->reg($src);
            $code .= pack( 'L<', 0x8B000000 | ( $s << 16 ) | ( $d << 5 ) | $d );
        }

        method mul_reg( $dest, $src ) {
            my $d = $self->reg($dest);
            my $s = $self->reg($src);
            $code .= pack( 'L<', 0x9B007C00 | ( $s << 16 ) | ( $d << 5 ) | $d );
        }

        method cmp_reg_reg( $l, $r ) {
            my $ld = $self->reg($l);
            my $rd = $self->reg($r);
            $code .= pack( 'L<', 0xEB000000 | ( $rd << 16 ) | 31 | ( $ld << 5 ) );
        }
        method setcc( $cc, $dest ) { my $d = $self->reg($dest); my $inv = $cc ^ 1; $code .= pack( 'L<', 0x9A9F03E0 | ( $inv << 12 ) | $d ) }

        method test_reg_reg( $l, $r ) {
            my $ld = $self->reg($l);
            my $rd = $self->reg($r);
            $code .= pack( 'L<', 0xEA000000 | ( $rd << 16 ) | 31 | ( $ld << 5 ) );
        }

        method load_reg_mem( $dest, $src, $disp = 0 ) {
            my $d = $self->reg($dest);
            my $s = $self->reg($src);
            $code .= pack( 'L<', 0xF9400000 | ( ( $disp >> 3 ) << 10 ) | ( $s << 5 ) | $d );
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

        method store_mem_disp_byte( $base, $disp, $src ) {
            my $b = $self->reg($base);
            my $s = $self->reg($src);
            $code .= pack( 'L<', 0x39000000 | ( $disp << 10 ) | ( $b << 5 ) | $s );
        }

        method lea_rva( $reg, $trva, $txtrva ) {
            my $r   = $self->reg($reg);
            my $off = $trva - ( $txtrva + length($code) );
            my $lo  = $off & 0x3;
            my $hi  = ( $off >> 2 ) & 0x7FFFF;
            $code .= pack( 'L<', 0x10000000 | ( $lo << 29 ) | ( $hi << 5 ) | $r );
        }
        method call_label($l)    { push @fixups, { offset => length($code), target => $l, type => 'call' }; $code .= pack( 'L<', 0x94000000 ) }
        method syscall( $m = 0 ) { $code .= pack( 'L<', $m ? 0xD4001001 : 0xD4000001 ) }

        method jcc( $cc, $l ) {
            push @fixups, { offset => length($code), target => $l, type => 'cond', cc => $cc };
            $code .= pack( 'L<', 0x54000000 | $cc );
        }
        method jmp($l)        { push @fixups, { offset => length($code), target => $l, type => 'uncond' }; $code .= pack( 'L<', 0x14000000 ) }
        method mark_label($n) { $labels{$n} = length $code }

        method resolve {
            for (@fixups) {
                my $t     = $labels{ $_->{target} };
                my $off   = ( $t - $_->{offset} ) / 4;
                my $instr = unpack( 'L<', substr( $code, $_->{offset}, 4 ) );
                if   ( $_->{type} eq 'cond' ) { $instr |= ( $off & 0x7FFFF ) << 5 }
                else                          { $instr |= ( $off & 0x3FFFFFF ) }
                substr( $code, $_->{offset}, 4, pack( 'L<', $instr ) );
            }
        }

        method call_rva( $trva, $txtrva ) {
            my $off = $trva - ( $txtrva + length($code) );
            my $lo  = $off & 0x3;
            my $hi  = ( $off >> 2 ) & 0x7FFFF;
            $code .= pack( 'L<', 0x10000000 | ( $lo << 29 ) | ( $hi << 5 ) | 16 );
            $code .= pack( 'L<', 0xF9400210 );
            $code .= pack( 'L<', 0xD63F0200 );
        }
    }

    class Brocken::Emit::X64 {
        field $code : reader = '';
        field %labels;
        field @fixups;

        method reg($r) {
            state $MAP = {
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
            };
            return $r if defined($r) && $r =~ /^\d+$/;
            my $name = lc( $r // '' );
            $name =~ s/^\s+|\s+$//g;
            die "Unknown X64 register: '$r'" unless exists $MAP->{$name};
            return $MAP->{$name};
        }

        method _rex( $w, $r, $x, $b ) {
            my $ri  = $self->reg($r);
            my $xi  = $self->reg($x);
            my $bi  = $self->reg($b);
            my $rex = 0x40;
            if ($w)         { $rex |= 0x08; }
            if ( $ri >= 8 ) { $rex |= 0x04; }
            if ( $xi >= 8 ) { $rex |= 0x02; }
            if ( $bi >= 8 ) { $rex |= 0x01; }
            if ( !$w && ( ( $ri >= 4 && $ri <= 7 ) || ( $bi >= 4 && $bi <= 7 ) ) ) { return pack( 'C', $rex ); }
            return ( $rex == 0x40 && !$w ) ? '' : pack( 'C', $rex );
        }

        method _emit_modrm( $opcode, $reg, $base, $disp, $w = 1, $prefix = '' ) {
            my $ri  = $self->reg($reg);
            my $bi  = $self->reg($base);
            my $mod = ( $disp == 0 && ( $bi & 7 ) != 5 ) ? 0 : ( $disp >= -128 && $disp <= 127 ? 1 : 2 );
            $code
                .= $self->_rex( $w, $ri, 0, $bi ) . $prefix . pack( 'C', $opcode ) . pack( 'C', ( $mod << 6 ) | ( ( $ri & 7 ) << 3 ) | ( $bi & 7 ) );
            if    ( ( $bi & 7 ) == 4 )                               { $code .= pack( 'C',  0x24 ); }
            if    ( $mod == 1 )                                      { $code .= pack( 'c',  $disp ); }
            elsif ( $mod == 2 || ( $mod == 0 && ( $bi & 7 ) == 5 ) ) { $code .= pack( 'l<', $disp ); }
        }
        method append_code($bin) { $code .= $bin }

        method mov_reg( $d, $s ) {
            my $di = $self->reg($d);
            my $si = $self->reg($s);
            $code .= $self->_rex( 1, $si, 0, $di ) . pack( 'CC', 0x89, 0xC0 | ( ( $si & 7 ) << 3 ) | ( $di & 7 ) );
        }
        method mov_imm( $r, $imm ) { my $ri = $self->reg($r); $code .= $self->_rex( 1, 0, 0, $ri ) . pack( 'Cq<', 0xB8 + ( $ri & 7 ), $imm ); }

        method push_reg($r) {
            my $ri = $self->reg($r);
            if ( $ri >= 8 ) { $code .= pack( 'CC', 0x41, 0x50 | ( $ri & 7 ) ); }
            else            { $code .= pack( 'C', 0x50 | $ri ); }
        }

        method pop_reg($r) {
            my $ri = $self->reg($r);
            if ( $ri >= 8 ) { $code .= pack( 'CC', 0x41, 0x58 | ( $ri & 7 ) ); }
            else            { $code .= pack( 'C', 0x58 | $ri ); }
        }
        method idiv_reg($src) { my $si = $self->reg($src); $code .= $self->_rex( 1, 0, 0, $si ) . pack( 'CC', 0xF7, 0xF8 | ( $si & 7 ) ); }
        method store_mem_disp_byte( $base, $disp, $src )   { $self->_emit_modrm( 0x88, $src, $base, $disp, 0 ); }
        method store_mem_disp_reg( $base, $disp, $src )    { $self->_emit_modrm( 0x89, $src, $base, $disp, 1 ); }
        method load_reg_mem( $dest, $src, $disp = 0 )      { $self->_emit_modrm( 0x8B, $dest, $src, $disp, 1 ); }
        method load_reg_mem_byte( $dest, $src, $disp = 0 ) { $self->_emit_modrm( 0xB6, $dest, $src, $disp, 1, pack( 'C', 0x0F ) ); }
        method lea_reg_disp( $dest, $base, $disp )         { $self->_emit_modrm( 0x8D, $dest, $base, $disp, 1 ); }

        method cmp_reg_imm( $r, $imm ) {
            my $ri = $self->reg($r);
            $code .= $self->_rex( 1, 0, 0, $ri ) . pack( 'CCl<', 0x81, 0xF8 | ( $ri & 7 ), $imm );
        }

        method cmp_reg_imm_32( $r, $imm ) {
            my $ri = $self->reg($r);
            $code .= $self->_rex( 0, 0, 0, $ri ) . pack( 'CCl<', 0x81, 0xF8 | ( $ri & 7 ), $imm );
        }

        method setcc( $cc, $r ) {
            my $ri = $self->reg($r);
            $code .= pack( 'C', 0x40 | ( $ri >= 8 ? 1 : 0 ) ) . pack( 'CCC', 0x0F, $cc, 0xC0 | ( $ri & 7 ) );
        }
        method add_imm( $r, $i ) { my $ri = $self->reg($r); $code .= $self->_rex( 1, 0, 0, $ri ) . pack( 'CCl<', 0x81, 0xC0 | ( $ri & 7 ), $i ); }
        method sub_imm( $r, $i ) { my $ri = $self->reg($r); $code .= $self->_rex( 1, 0, 0, $ri ) . pack( 'CCl<', 0x81, 0xE8 | ( $ri & 7 ), $i ); }

        method add_reg( $d, $s ) {
            my $di = $self->reg($d);
            my $si = $self->reg($s);
            $code .= $self->_rex( 1, $si, 0, $di ) . pack( 'CC', 0x01, 0xC0 | ( ( $si & 7 ) << 3 ) | ( $di & 7 ) );
        }

        method sub_reg( $d, $s ) {
            my $di = $self->reg($d);
            my $si = $self->reg($s);
            $code .= $self->_rex( 1, $si, 0, $di ) . pack( 'CC', 0x29, 0xC0 | ( ( $si & 7 ) << 3 ) | ( $di & 7 ) );
        }

        method mul_reg( $d, $s ) {
            my $di = $self->reg($d);
            my $si = $self->reg($s);
            $code .= $self->_rex( 1, $di, 0, $si ) . pack( 'CCC', 0x0F, 0xAF, 0xC0 | ( ( $di & 7 ) << 3 ) | ( $si & 7 ) );
        }

        method test_reg_reg( $l, $r ) {
            my $li = $self->reg($l);
            my $ri = $self->reg($r);
            $code .= $self->_rex( 1, $ri, 0, $li ) . pack( 'CC', 0x85, 0xC0 | ( ( $ri & 7 ) << 3 ) | ( $li & 7 ) );
        }

        method cmp_reg_reg( $l, $r ) {
            my $li = $self->reg($l);
            my $ri = $self->reg($r);
            $code .= $self->_rex( 1, $ri, 0, $li ) . pack( 'CC', 0x39, 0xC0 | ( ( $ri & 7 ) << 3 ) | ( $li & 7 ) );
        }

        method lea_rva( $reg, $target, $txtrva = 0 ) {
            my $ri = $self->reg($reg);
            if ( $target =~ /^[A-Z_]/i ) {
                $code .= $self->_rex( 1, $ri, 0, 0 ) . pack( 'CC', 0x8D, 0x05 | ( ( $ri & 7 ) << 3 ) );
                push @fixups, { offset => length($code), target => $target };
                $code .= pack( 'L<', 0 );
            }
            else {
                my $next = $txtrva + length($code) + 7;
                $code .= $self->_rex( 1, $ri, 0, 0 ) . pack( 'CC l<', 0x8D, 0x05 | ( ( $ri & 7 ) << 3 ), $target - $next );
            }
        }
        method call_rva( $trva, $txtrva ) { my $next = $txtrva + length($code) + 6; $code .= pack( 'CC l<', 0xFF, 0x15, $trva - $next ); }
        method push_imm($imm)             { $code .= pack( 'Cl<', 0x68, $imm ); }
        method syscall        { $code .= pack 'CC', 0x0F, 0x05 }
        method call_label($l) { $code .= pack( 'C', 0xE8 ); push @fixups, { offset => length($code), target => $l }; $code .= pack( 'L<', 0 ); }
        method mark_label($n) { $labels{$n} = length $code }
        method jmp($l)        { $code .= pack( 'C', 0xE9 ); push @fixups, { offset => length($code), target => $l }; $code .= pack( 'L<', 0 ); }

        method jcc( $cc, $l ) {
            $code .= pack( 'CC', 0x0F, 0x80 + $cc );
            push @fixups, { offset => length($code), target => $l };
            $code .= pack( 'L<', 0 );
        }

        method resolve {
            for (@fixups) { my $t = $labels{ $_->{target} }; substr( $code, $_->{offset}, 4, pack( 'l<', $t - ( $_->{offset} + 4 ) ) ); }
        }
    }
}
1;
