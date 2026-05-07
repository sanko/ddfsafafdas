package Brocken::Target::X64::Emit {
    use v5.40;
    use feature 'class';
    no warnings 'experimental::class';

    class Brocken::Target::X64::Emit {
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
            $rex |= 0x08 if $w;
            $rex |= 0x04 if $ri >= 8;
            $rex |= 0x02 if $xi >= 8;
            $rex |= 0x01 if $bi >= 8;
            if ( !$w && ( ( $ri >= 4 && $ri <= 7 ) || ( $bi >= 4 && $bi <= 7 ) ) ) { return pack( 'C', $rex ); }
            return ( $rex == 0x40 && !$w ) ? '' : pack( 'C', $rex );
        }

        method _emit_modrm( $opcode, $reg, $base, $disp, $w = 1, $prefix = '' ) {
            my $ri  = $self->reg($reg);
            my $bi  = $self->reg($base);
            my $mod = ( $disp == 0 && ( $bi & 7 ) != 5 ) ? 0 : ( $disp >= -128 && $disp <= 127 ? 1 : 2 );
            $code
                .= $self->_rex( $w, $ri, 0, $bi ) . $prefix . pack( 'C', $opcode ) . pack( 'C', ( $mod << 6 ) | ( ( $ri & 7 ) << 3 ) | ( $bi & 7 ) );
            $code .= pack( 'C', 0x24 ) if ( ( $bi & 7 ) == 4 );
            if    ( $mod == 1 )                                      { $code .= pack( 'c',  $disp ); }
            elsif ( $mod == 2 || ( $mod == 0 && ( $bi & 7 ) == 5 ) ) { $code .= pack( 'l<', $disp ); }
        }
        method append_code($bin) { $code .= $bin }
        method mark_label($n)    { $labels{$n} = length $code }

        method mov_reg( $d, $s ) {
            my $di = $self->reg($d);
            my $si = $self->reg($s);
            $code .= $self->_rex( 1, $si, 0, $di ) . pack( 'CC', 0x89, 0xC0 | ( ( $si & 7 ) << 3 ) | ( $di & 7 ) );
        }

        method mov_imm( $r, $imm ) {
            my $ri = $self->reg($r);
            $code .= $self->_rex( 1, 0, 0, $ri ) . pack( 'Cq<', 0xB8 + ( $ri & 7 ), $imm );
        }

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
        method add_imm( $r, $i ) { my $ri = $self->reg($r); $code .= $self->_rex( 1, 0, 0, $ri ) . pack( 'CCl<', 0x81, 0xC0 | ( $ri & 7 ), $i ); }
        method sub_imm( $r, $i ) { my $ri = $self->reg($r); $code .= $self->_rex( 1, 0, 0, $ri ) . pack( 'CCl<', 0x81, 0xE8 | ( $ri & 7 ), $i ); }

        method add_reg( $d, $s ) {
            $code .= $self->_rex( 1, $self->reg($s), 0, $self->reg($d) ) .
                pack( 'CC', 0x01, 0xC0 | ( ( $self->reg($s) & 7 ) << 3 ) | ( $self->reg($d) & 7 ) );
        }

        method sub_reg( $d, $s ) {
            $code .= $self->_rex( 1, $self->reg($s), 0, $self->reg($d) ) .
                pack( 'CC', 0x29, 0xC0 | ( ( $self->reg($s) & 7 ) << 3 ) | ( $self->reg($d) & 7 ) );
        }

        method mul_reg( $d, $s ) {
            $code .= $self->_rex( 1, $self->reg($d), 0, $self->reg($s) ) .
                pack( 'CCC', 0x0F, 0xAF, 0xC0 | ( ( $self->reg($d) & 7 ) << 3 ) | ( $self->reg($s) & 7 ) );
        }
        method idiv_reg($src) { $code .= $self->_rex( 1, 0, 0, $self->reg($src) ) . pack( 'CC', 0xF7, 0xF8 | ( $self->reg($src) & 7 ) ); }

        method test_reg_reg( $l, $r ) {
            $code .= $self->_rex( 1, $self->reg($r), 0, $self->reg($l) ) .
                pack( 'CC', 0x85, 0xC0 | ( ( $self->reg($r) & 7 ) << 3 ) | ( $self->reg($l) & 7 ) );
        }

        method cmp_reg_reg( $l, $r ) {
            $code .= $self->_rex( 1, $self->reg($r), 0, $self->reg($l) ) .
                pack( 'CC', 0x39, 0xC0 | ( ( $self->reg($r) & 7 ) << 3 ) | ( $self->reg($l) & 7 ) );
        }

        method cmp_reg_imm( $r, $imm ) {
            $code .= $self->_rex( 1, 0, 0, $self->reg($r) ) . pack( 'CCl<', 0x81, 0xF8 | ( $self->reg($r) & 7 ), $imm );
        }
        method cmp_reg_imm_32( $r, $i ) { $code .= $self->_rex( 0, 0, 0, $self->reg($r) ) . pack( 'CCl<', 0x81, 0xF8 | ( $self->reg($r) & 7 ), $i ); }

        method setcc( $cc, $r ) {
            my $ri = $self->reg($r);
            $code .= pack( 'C', 0x40 | ( $ri >= 8 ? 1 : 0 ) ) . pack( 'CCC', 0x0F, $cc, 0xC0 | ( $ri & 7 ) );
        }
        method store_mem_disp_byte( $b, $d, $s )     { $self->_emit_modrm( 0x88, $s, $b, $d, 0 ); }
        method store_mem_disp_reg( $b, $d, $s )      { $self->_emit_modrm( 0x89, $s, $b, $d, 1 ); }
        method load_reg_mem( $d, $s, $off = 0 )      { $self->_emit_modrm( 0x8B, $d, $s, $off, 1 ); }
        method load_reg_mem_byte( $d, $s, $off = 0 ) { $self->_emit_modrm( 0xB6, $d, $s, $off, 1, pack( 'C', 0x0F ) ); }
        method lea_reg_disp( $d, $b, $off )          { $self->_emit_modrm( 0x8D, $d, $b, $off, 1 ); }

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

        method call_rva( $trva, $txtrva ) {
            my $next = $txtrva + length($code) + 6;
            $code .= pack( 'CC l<', 0xFF, 0x15, $trva - $next );
        }

        method call_label($l) {
            $code .= pack( 'C', 0xE8 );
            push @fixups, { offset => length($code), target => $l };
            $code .= pack( 'L<', 0 );
        }

        method jmp($l) {
            $code .= pack( 'C', 0xE9 );
            push @fixups, { offset => length($code), target => $l };
            $code .= pack( 'L<', 0 );
        }

        method jcc( $cc, $l ) {
            $code .= pack( 'CC', 0x0F, 0x80 + $cc );
            push @fixups, { offset => length($code), target => $l };
            $code .= pack( 'L<', 0 );
        }
        method syscall { $code .= pack 'CC', 0x0F, 0x05 }

        method resolve {
            for (@fixups) {
                my $t = $labels{ $_->{target} };
                die "Linker Error: Unresolved label '$_->{target}'\n" unless defined $t;
                substr( $code, $_->{offset}, 4, pack( 'l<', $t - ( $_->{offset} + 4 ) ) );
            }
        }
    }
}
1;
