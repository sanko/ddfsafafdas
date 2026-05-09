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
    method add_imm( $reg, $imm )  { my $r  = $self->reg($reg);  $code .= pack( 'L<', 0x91000000 | ( ( $imm & 0xFFF ) << 10 ) | ( $r << 5 ) | $r ) }
    method sub_imm( $reg, $imm )  { my $r  = $self->reg($reg);  $code .= pack( 'L<', 0xD1000000 | ( ( $imm & 0xFFF ) << 10 ) | ( $r << 5 ) | $r ) }

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

    method setcc( $cc, $r ) {
        my $ri = $self->reg($r);

        # REX prefix is required to access the low byte of R8-R15 or if using Sil/Dil
        my $rex = 0x40 | ( $ri >= 8 ? 1 : 0 );
        $code .= pack( 'C', $rex ) . pack( 'CCC', 0x0F, $cc, 0xC0 | ( $ri & 7 ) );
    }

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
1;
__END__

=pod

=head1 NAME

Brocken::Emit::ARM64 - ARM64 emitter (alternate entry point)

=head1 DESCRIPTION

Duplicate/shadow of Brocken::Target::ARM64::Emit. Provides the same A64 instruction encoding interface. May be
consolidated in a future refactor.

=cut
