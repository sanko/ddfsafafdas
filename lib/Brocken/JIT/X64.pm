package Brocken::JIT::X64 {
    use v5.40;
    use utf8;
    use feature 'class';
    no warnings 'experimental::class';

    class Brocken::JIT::X64 {
        field $code : reader = '';
        field %labels;
        field @fixups;

        method reg($r) {
            state $MAP = {
                rax   => 0,
                eax   => 0,
                ax    => 0,
                al    => 0,
                rcx   => 1,
                ecx   => 1,
                cx    => 1,
                cl    => 1,
                rdx   => 2,
                edx   => 2,
                dx    => 2,
                dl    => 2,
                rbx   => 3,
                ebx   => 3,
                bx    => 3,
                bl    => 3,
                rsp   => 4,
                esp   => 4,
                sp    => 4,
                spl   => 4,
                rbp   => 5,
                ebp   => 5,
                bp    => 5,
                bpl   => 5,
                rsi   => 6,
                esi   => 6,
                si    => 6,
                sil   => 6,
                rdi   => 7,
                edi   => 7,
                di    => 7,
                dil   => 7,
                r8    => 8,
                r9    => 9,
                r10   => 10,
                r11   => 11,
                r12   => 12,
                r13   => 13,
                r14   => 14,
                r15   => 15,
                xmm0  => 0,
                xmm1  => 1,
                xmm2  => 2,
                xmm3  => 3,
                xmm4  => 4,
                xmm5  => 5,
                xmm6  => 6,
                xmm7  => 7,
                xmm8  => 8,
                xmm9  => 9,
                xmm10 => 10,
                xmm11 => 11,
                xmm12 => 12,
                xmm13 => 13,
                xmm14 => 14,
                xmm15 => 15,
                xip   => 16
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

        method movq_reg_xmm( $d, $s ) {
            my $di = $self->reg($d);
            my $si = $self->reg($s);
            $code
                .= pack( 'C', 0x66 ) .
                $self->_rex( 1, $di, 0, $si ) .
                pack( 'CC', 0x0F, 0x6E ) .
                pack( 'C', 0xC0 | ( ( $di & 7 ) << 3 ) | ( $si & 7 ) );
        }

        method movq_xmm_reg( $d, $s ) {
            my $di = $self->reg($d);
            my $si = $self->reg($s);
            $code
                .= pack( 'C', 0x66 ) .
                $self->_rex( 1, $si, 0, $di ) .
                pack( 'CC', 0x0F, 0x7E ) .
                pack( 'C', 0xC0 | ( ( $si & 7 ) << 3 ) | ( $di & 7 ) );
        }

        method movq_xmm_mem( $s, $b, $disp = 0 ) {
            my $si = $self->reg($s);
            my $bi = $self->reg($b);
            $code .= pack( 'C', 0x66 ) . $self->_rex( 0, $si, 0, $bi ) . pack( 'CC', 0x0F, 0xD6 );
            my $mod = ( $disp == 0 && ( $bi & 7 ) != 5 ) ? 0 : ( $disp >= -128 && $disp <= 127 ? 1 : 2 );
            $code .= pack( 'C', ( $mod << 6 ) | ( ( $si & 7 ) << 3 ) | ( $bi & 7 ) );
            $code .= pack( 'C', 0x24 ) if ( ( $bi & 7 ) == 4 );
            if    ( $mod == 1 )                                      { $code .= pack( 'c',  $disp ); }
            elsif ( $mod == 2 || ( $mod == 0 && ( $bi & 7 ) == 5 ) ) { $code .= pack( 'l<', $disp ); }
        }

        method addsd_reg( $d, $s ) {
            $code
                .= pack( 'C', 0xF2 ) .
                $self->_rex( 0, $self->reg($s), 0, $self->reg($d) ) .
                pack( 'CC', 0x0F, 0x58 ) .
                pack( 'C', 0xC0 | ( ( $self->reg($s) & 7 ) << 3 ) | ( $self->reg($d) & 7 ) );
        }

        method subsd_reg( $d, $s ) {
            $code
                .= pack( 'C', 0xF2 ) .
                $self->_rex( 0, $self->reg($s), 0, $self->reg($d) ) .
                pack( 'CC', 0x0F, 0x5C ) .
                pack( 'C', 0xC0 | ( ( $self->reg($s) & 7 ) << 3 ) | ( $self->reg($d) & 7 ) );
        }

        method mulsd_reg( $d, $s ) {
            $code
                .= pack( 'C', 0xF2 ) .
                $self->_rex( 0, $self->reg($s), 0, $self->reg($d) ) .
                pack( 'CC', 0x0F, 0x59 ) .
                pack( 'C', 0xC0 | ( ( $self->reg($s) & 7 ) << 3 ) | ( $self->reg($d) & 7 ) );
        }

        method divsd_reg( $d, $s ) {
            $code
                .= pack( 'C', 0xF2 ) .
                $self->_rex( 0, $self->reg($s), 0, $self->reg($d) ) .
                pack( 'CC', 0x0F, 0x5E ) .
                pack( 'C', 0xC0 | ( ( $self->reg($s) & 7 ) << 3 ) | ( $self->reg($d) & 7 ) );
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
                $code .= $self->_rex( 1, 0, 0, $ri ) . pack( 'CCl<', 0x81, 0xC0 | ( $ri & 7 ), $imm );
            }
            else {
                $self->mov_imm( 'r11', $imm );
                $self->add_reg( $r, 'r11' );
            }
        }

        method mul_imm( $dest, $imm ) {

            # x64 doesn't have a simple 2-operand mul with immediate.
            # We load the immediate into scratch r11 and use the register multiplier.
            $self->mov_imm( 'r11', $imm );
            $self->mul_reg( $dest, 'r11' );
        }

        method sub_reg( $d, $s ) {
            my $di = $self->reg($d);
            my $si = $self->reg($s);
            $code .= $self->_rex( 1, $si, 0, $di ) . pack( 'CC', 0x29, 0xC0 | ( ( $si & 7 ) << 3 ) | ( $di & 7 ) );
        }

        method sub_imm( $r, $imm ) {
            my $ri = $self->reg($r);
            if ( $imm >= -2147483648 && $imm <= 2147483647 ) {
                $code .= $self->_rex( 1, 0, 0, $ri ) . pack( 'CCl<', 0x81, 0xE8 | ( $ri & 7 ), $imm );
            }
            else {
                $self->mov_imm( 'r11', $imm );
                $self->sub_reg( $r, 'r11' );
            }
        }

        method and_imm( $r, $imm ) {
            my $ri = $self->reg($r);
            if ( $imm >= -2147483648 && $imm <= 2147483647 ) {
                $code .= $self->_rex( 1, 0, 0, $ri ) . pack( 'CCl<', 0x81, 0xE0 | ( $ri & 7 ), $imm );
            }
            else {
                $self->mov_imm( 'r11', $imm );
                $self->and_reg( $r, 'r11' );
            }
        }

        method or_imm( $r, $imm ) {
            my $ri = $self->reg($r);
            if ( $imm >= -2147483648 && $imm <= 2147483647 ) {
                $code .= $self->_rex( 1, 0, 0, $ri ) . pack( 'CCl<', 0x81, 0xC8 | ( $ri & 7 ), $imm );
            }
            else {
                $self->mov_imm( 'r11', $imm );
                $self->or_reg( $r, 'r11' );
            }
        }

        method xor_imm( $r, $imm ) {
            my $ri = $self->reg($r);
            if ( $imm >= -2147483648 && $imm <= 2147483647 ) {
                $code .= $self->_rex( 1, 0, 0, $ri ) . pack( 'CCl<', 0x81, 0xF0 | ( $ri & 7 ), $imm );
            }
            else {
                $self->mov_imm( 'r11', $imm );
                $self->xor_reg( $r, 'r11' );
            }
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
            push @fixups, { offset => length($code), target => $label };
            $code .= pack( 'l<', 0 );
        }

        method jcc( $cc, $label ) {
            my $ccode = {
                0  => 0x84,
                1  => 0x85,
                2  => 0x82,
                3  => 0x83,
                4  => 0x8C,
                5  => 0x8D,
                6  => 0x8E,
                7  => 0x8F,
                nz => 0x85,
                eq => 0x84,
                lt => 0x8C,
                gt => 0x8F,
                le => 0x8E,
                ge => 0x8D
            };
            my $op = $ccode->{$cc} // die "Unknown cc: $cc";
            $code .= pack( 'C', 0x0F );
            $code .= pack( 'C', $op );
            push @fixups, { offset => length($code), target => $label };
            $code .= pack( 'l<', 0 );
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

        method mul_reg( $dest, $src ) {

            # Brocken Target logic moves the first operand to RAX, then calls mul_reg(dest, src)
            # We map this to the x64 IMUL r, r instruction for simplicity
            my $di = $self->reg($dest);
            my $si = $self->reg($src);
            $code .= $self->_rex( 1, $di, 0, $si ) . pack( 'CCC', 0x0F, 0xAF, 0xC0 | ( ( $di & 7 ) << 3 ) | ( $si & 7 ) );
        }

        method call_label($label) {
            $code .= pack( 'C', 0xE8 );
            push @fixups, { offset => length($code), target => $label };
            $code .= pack( 'l<', 0 );
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

        method mov_label( $r, $label ) {
            my $ri = $self->reg($r);
            $code .= $self->_rex( 1, 0, 0, $ri ) . pack( 'C', 0xB8 + ( $ri & 7 ) );
            push @fixups, { offset => length($code), target => $label, type => 'absolute' };
            $code .= pack( 'Q<', 0 );
        }

        method resolve( $base_addr = 0 ) {
            for my $fixup (@fixups) {
                my $target_pos = $labels{ $fixup->{target} };
                die "Unresolved label: $fixup->{target}" unless defined $target_pos;
                my $offset = $fixup->{offset};
                if ( ( $fixup->{type} // '' ) eq 'absolute' ) {
                    substr( $code, $offset, 8 ) = pack( 'Q<', $base_addr + $target_pos );
                }
                else {
                    my $rel = $target_pos - ( $offset + 4 );
                    substr( $code, $offset, 4 ) = pack( 'l<', $rel );
                }
            }
            @fixups = ();
        }
    }
}
1;
__END__

=pod

=head1 NAME

Brocken::JIT::X64 - JIT assembler for x64 architecture

=head1 SYNOPSIS

  my $as = Brocken::JIT::X64->new();
  $as->mov_imm('rax', 42);
  $as->ret();
  my $code = $as->code;

=head1 DESCRIPTION

Standalone JIT assembler that generates x64 machine code without PE format dependencies. Supports a subset of x64
instructions needed for the Brocken JIT.

=head1 FIELDS

=over

=item code

The generated machine code string. Use the C<code> reader to access it.

=back

=head1 METHODS

=head2 reg($name)

Maps a register name (e.g., 'rax', 'r11', 'xmm0') to its internal numeric ID. Dies if the register name is
unrecognized.

=head2 mov_reg($dest, $src)

Emits a MOV instruction between registers (64-bit).

=head2 mov_imm($dest, $imm)

Emits a MOV instruction from a 64-bit immediate value to a register.

=head2 push_reg($reg) / pop_reg($reg)

Emits PUSH/POP instructions for 64-bit registers.

=head2 add_reg / sub_reg / mul_reg / and_reg / or_reg / xor_reg

Emits 2-operand arithmetic/logic instructions between registers.

=head2 add_imm / sub_imm / and_imm / or_imm / xor_imm

Emits arithmetic/logic instructions with an immediate operand.  If the immediate exceeds 32 bits, it is loaded into a
scratch register first.

=head2 jmp($label) / jcc($condition, $label)

Emits relative jumps. C<$condition> can be 'nz', 'eq', 'lt', 'gt', 'le', 'ge'. Labels are resolved during the
C<resolve()> phase.

=head2 mark_label($name)

Defines a label at the current code position.

=head2 resolve($base_addr)

Resolves all relative and absolute fixups using the provided base address. Should be called after all code has been
emitted but before the code is copied to its final executable location.

=cut
