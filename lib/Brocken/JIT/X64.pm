package Brocken::JIT::X64 {
    use v5.40;
    use utf8;
    use feature 'class';
    no warnings 'experimental::class';

    class Brocken::JIT::X64 {
        field $code : reader = '';
        field %labels;

        method reg($r) {
            state $MAP = {
                rax => 0, rcx => 1, rdx => 2, rbx => 3,
                rsp => 4, rbp => 5, rsi => 6, rdi => 7,
                r8  => 8, r9  => 9, r10 => 10, r11 => 11,
                r12 => 12, r13 => 13, r14 => 14, r15 => 15,
                xip => 16
            };
            my $name = lc( $r // '' );
            $name =~ s/^\s+|\s+$//g;
            die "Logic Error: Expected X64 register name, got '$r'" unless exists $MAP->{$name};
            return $MAP->{$name};
        }

        method _rex( $w, $ri, $xi, $bi ) {
            my $rex = 0x40;
            $rex |= 0x08 if $w;
            $rex |= 0x04 if ( $ri // 0 ) >= 8;
            $rex |= 0x02 if ( $xi // 0 ) >= 8;
            $rex |= 0x01 if ( $bi // 0 ) >= 8;
            return ( $rex == 0x40 && !$w ) ? '' : pack( 'C', $rex );
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

        method add_reg( $d, $s ) {
            my $di = $self->reg($d);
            my $si = $self->reg($s);
            $code .= $self->_rex( 1, $si, 0, $di ) . pack( 'CC', 0x01, 0xC0 | ( ( $si & 7 ) << 3 ) | ( $di & 7 ) );
        }

        method add_imm( $r, $imm ) {
            my $ri = $self->reg($r);
            if ( $imm >= -2147483648 && $imm <= 2147483647 ) {
                $code .= $self->_rex( 1, 0, 0, $ri ) . pack( 'Ci<', 0x81, 0xC0 | ( $ri & 7 ), $imm );
            }
            else {
                $self->mov_imm( 'r11', $imm );
                $self->add_reg( $r, 'r11' );
            }
        }

        method sub_reg( $d, $s ) {
            my $di = $self->reg($d);
            my $si = $self->reg($s);
            $code .= $self->_rex( 1, $si, 0, $di ) . pack( 'CC', 0x29, 0xC0 | ( ( $si & 7 ) << 3 ) | ( $di & 7 ) );
        }

        method sub_imm( $r, $imm ) {
            my $ri = $self->reg($r);
            $self->mov_imm( 'r11', $imm );
            $self->sub_reg( $r, 'r11' );
        }

        method and_reg( $d, $s ) {
            my $di = $self->reg($d);
            my $si = $self->reg($s);
            $code .= $self->_rex( 1, $si, 0, $di ) . pack( 'CC', 0x21, 0xC0 | ( ( $si & 7 ) << 3 ) | ( $di & 7 ) );
        }

        method or_reg( $d, $s ) {
            my $di = $self->reg($d);
            my $si = $self->reg($s);
            $code .= $self->_rex( 1, $si, 0, $di ) . pack( 'CC', 0x09, 0xC0 | ( ( $si & 7 ) << 3 ) | ( $di & 7 ) );
        }

        method xor_reg( $d, $s ) {
            my $di = $self->reg($d);
            my $si = $self->reg($s);
            $code .= $self->_rex( 1, $si, 0, $di ) . pack( 'CC', 0x31, 0xC0 | ( ( $si & 7 ) << 3 ) | ( $di & 7 ) );
        }

        method test_reg_reg( $r1, $r2 ) {
            my $ri = $self->reg($r1);
            my $si = $self->reg($r2);
            $code .= $self->_rex( 1, $ri, 0, $si ) . pack( 'CC', 0x85, 0xC0 | ( ( $ri & 7 ) << 3 ) | ( $si & 7 ) );
        }

        method jmp($label) {
            $code .= pack( 'C', 0xE9 );
            my $target = $labels{$label} // die "Unknown label: $label";
            my $dist = $target - length($code) - 4;
            $code .= pack( 'l<', $dist );
        }

        method jcc( $cc, $label ) {
            my $ccode = { 0 => 0x84, 1 => 0x85, 2 => 0x82, 3 => 0x83, 4 => 0x8C, 5 => 0x8D, 6 => 0x8E, 7 => 0x8F,
                          nz => 0x85, eq => 0x84, lt => 0x8C, gt => 0x8F, le => 0x8E, ge => 0x8D };
            my $op = $ccode->{$cc} // die "Unknown cc: $cc";
            $code .= pack( 'C', 0x0F );
            $code .= pack( 'C', $op );
            my $target = $labels{$label} // die "Unknown label: $label";
            my $dist = $target - length($code) - 4;
            $code .= pack( 'l<', $dist );
        }

        method lea_reg_disp( $d, $b, $off ) {
            my $di = $self->reg($d);
            my $bi = $self->reg($b);
            if ( $off == 0 && ( $bi & 7 ) != 5 ) {
                $code .= $self->_rex( 1, $di, 0, $bi ) . pack( 'CC', 0x8D, 0x00 | ( ( $di & 7 ) << 3 ) | ( $bi & 7 ) );
            }
            elsif ( $off >= -128 && $off <= 127 ) {
                $code .= $self->_rex( 1, $di, 0, $bi ) . pack( 'CCc', 0x8D, 0x40 | ( ( $di & 7 ) << 3 ) | ( $bi & 7 ), $off );
            }
            else {
                $code .= $self->_rex( 1, $di, 0, $bi ) . pack( 'CCi<', 0x8D, 0x80 | ( ( $di & 7 ) << 3 ) | ( $bi & 7 ), $off );
            }
        }

        method load_reg_mem( $d, $b, $off ) {
            my $di = $self->reg($d);
            my $bi = $self->reg($b);
            if ( $off == 0 && ( $bi & 7 ) != 5 ) {
                $code .= $self->_rex( 1, $di, 0, $bi ) . pack( 'CC', 0x8B, 0x00 | ( ( $di & 7 ) << 3 ) | ( $bi & 7 ) );
            }
            elsif ( $off >= -128 && $off <= 127 ) {
                $code .= $self->_rex( 1, $di, 0, $bi ) . pack( 'CCc', 0x8B, 0x40 | ( ( $di & 7 ) << 3 ) | ( $bi & 7 ), $off );
            }
            else {
                $code .= $self->_rex( 1, $di, 0, $bi ) . pack( 'CCi<', 0x8B, 0x80 | ( ( $di & 7 ) << 3 ) | ( $bi & 7 ), $off );
            }
        }

        method store_mem_disp_reg( $b, $off, $s ) {
            my $bi = $self->reg($b);
            my $si = $self->reg($s);
            if ( $off == 0 && ( $bi & 7 ) != 5 ) {
                $code .= $self->_rex( 1, $si, 0, $bi ) . pack( 'CC', 0x89, 0x00 | ( ( $si & 7 ) << 3 ) | ( $bi & 7 ) );
            }
            elsif ( $off >= -128 && $off <= 127 ) {
                $code .= $self->_rex( 1, $si, 0, $bi ) . pack( 'CCc', 0x89, 0x40 | ( ( $si & 7 ) << 3 ) | ( $bi & 7 ), $off );
            }
            else {
                $code .= $self->_rex( 1, $si, 0, $bi ) . pack( 'CCi<', 0x89, 0x80 | ( ( $si & 7 ) << 3 ) | ( $bi & 7 ), $off );
            }
        }

        method store_mem_disp_byte( $b, $off, $s ) {
            my $bi = $self->reg($b);
            my $si = $self->reg($s);
            $code .= $self->_rex( 0, $si, 0, $bi ) . pack( 'CC', 0x88, 0x40 | ( ( $si & 7 ) << 3 ) | ( $bi & 7 ), $off );
        }

        method load_reg_mem_byte( $d, $b, $off ) {
            my $di = $self->reg($d);
            my $bi = $self->reg($b);
            $code .= $self->_rex( 0, $di, 0, $bi ) . pack( 'CC', 0x8A, 0x40 | ( ( $di & 7 ) << 3 ) | ( $bi & 7 ), $off );
        }

        method cmp_reg_imm( $r, $imm ) {
            my $ri = $self->reg($r);
            if ( $imm >= -2147483648 && $imm <= 2147483647 ) {
                $code .= $self->_rex( 1, 0, 0, $ri ) . pack( 'CCi<', 0x81, 0xF8 | ( $ri & 7 ), $imm );
            }
            else {
                $self->mov_imm( 'r11', $imm );
                $code .= $self->_rex( 1, $ri, 0, 11 ) . pack( 'CC', 0x39, 0xC0 | ( ( $ri & 7 ) << 3 ) | 11 );
            }
        }

        method cmp_reg_reg( $r1, $r2 ) {
            my $ri = $self->reg($r1);
            my $si = $self->reg($r2);
            $code .= $self->_rex( 1, $ri, 0, $si ) . pack( 'CC', 0x39, 0xC0 | ( ( $ri & 7 ) << 3 ) | ( $si & 7 ) );
        }

        method setcc( $cc, $r ) {
            my $ri = $self->reg($r);
            $code .= pack( 'CC', 0x0F, $cc );
            if ( $ri >= 8 ) { $code .= pack( 'CC', 0x41, 0x90 | ( $ri & 7 ) ); }
            else            { $code .= pack( 'C', 0x90 | $ri ); }
        }

        method shl_cl($r) {
            my $ri = $self->reg($r);
            $code .= $self->_rex( 1, 0, 0, $ri ) . pack( 'CC', 0xD3, 0xE0 | ( $ri & 7 ) );
        }

        method shr_cl($r) {
            my $ri = $self->reg($r);
            $code .= $self->_rex( 1, 0, 0, $ri ) . pack( 'CC', 0xD3, 0xE8 | ( $ri & 7 ) );
        }

        method shl_imm( $r, $amt ) {
            my $ri = $self->reg($r);
            $code .= $self->_rex( 1, 0, 0, $ri ) . pack( 'CC', 0xC1, 0xE0 | ( $ri & 7 ), $amt );
        }

        method shr_imm( $r, $amt ) {
            my $ri = $self->reg($r);
            $code .= $self->_rex( 1, 0, 0, $ri ) . pack( 'CC', 0xC1, 0xE8 | ( $ri & 7 ), $amt );
        }

        method idiv_reg($r) {
            my $ri = $self->reg($r);
            $code .= $self->_rex( 1, 0, 0, $ri ) . pack( 'CC', 0xF7, 0xF8 | ( $ri & 7 ) );
        }

        method mul_reg($r) {
            my $ri = $self->reg($r);
            $code .= $self->_rex( 1, 0, 0, $ri ) . pack( 'CC', 0xF7, 0xE0 | ( $ri & 7 ) );
        }

        method call_label($label) {
            my $target = $labels{$label} // die "Unknown label: $label";
            $code .= pack( 'C', 0xE8 );
            my $dist = $target - length($code) - 4;
            $code .= pack( 'l<', $dist );
        }

        method call_reg($r) {
            my $ri = $self->reg($r);
            if ( $ri >= 8 ) { $code .= pack( 'CCC', 0x41, 0xFF, 0xD0 | ( $ri & 7 ) ); }
            else            { $code .= pack( 'CC', 0xFF, 0xD0 | $ri ); }
        }

        method ret() {
            $code .= pack( 'C', 0xC3 );
        }

        method syscall() {
            $code .= pack( 'C', 0x0F );
            $code .= pack( 'C', 0x05 );
        }
    }
}
1;
__END__

=pod

=head1 NAME

Brocken::JIT::X64 - JIT assembler for x64 architecture

=head1 DESCRIPTION

Standalone JIT assembler that generates x64 machine code without PE format dependencies.

=cut
1;