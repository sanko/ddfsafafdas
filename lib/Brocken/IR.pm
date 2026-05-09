use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';

class Brocken::IR::Builder {
    field @instructions : reader;
    field $reg_count   = 0;
    field $label_count = 0;
    method new_reg()               { return '%' . ++$reg_count; }
    method new_label()             { return 'L' . ++$label_count; }
    method set_instructions(@inst) { @instructions = @inst }
    method push_instruction($inst) { push @instructions, $inst }
    method last_instruction()      { $instructions[-1] }

    method emit( $op, $type, $args, $dest = undef ) {
        if ( !defined($dest) && $type ne 'void' ) { $dest = $self->new_reg(); }
        push @instructions, { op => $op, type => $type, dest => $dest, args => $args };
        return $dest;
    }
    method emit_label($name) { push @instructions, { op => 'label', name   => $name }; }
    method emit_jump($label) { push @instructions, { op => 'jmp',   target => $label }; }
    method emit_cond_br( $reg, $tl, $fl ) { push @instructions, { op => 'cond_br', reg => $reg, true_l => $tl, false_l => $fl }; }

    method dump_ir ( $title //= () ) {
        say "\n=== $title ===" if $title;
        for my $i (@instructions) {
            my $op   = $i->{op}   // '???';
            my $dest = $i->{dest} // '';
            my @al;
            if ( $i->{args} ) {
                @al = map { !defined($_) ? 'undef' : ( ref($_) ? 'OBJ' : $_ ) } @{ $i->{args} };
            }
            elsif ( $i->{target} )          { push @al, 'target:' . $i->{target}; }
            elsif ( $i->{name} )            { push @al, 'name:' . $i->{name}; }
            elsif ( $i->{op} eq 'cond_br' ) { push @al, 'reg:' . $i->{reg} . ' t:' . $i->{true_l} . ' f:' . $i->{false_l}; }
            say sprintf( '  %-3s %-15s %-5s [%s]', ( $dest ? $dest : '' ), $op, ( $i->{type} // '' ), join( ', ', @al ) );
        }
    }
};
1;
__END__

=pod

=head1 NAME

Brocken::IR::Builder - Linear intermediate representation builder

=head1 DESCRIPTION

Manages a linear sequence of IR instruction hashes. Each instruction:

  { op => 'add', type => 'Int', dest => '%5', args => ['%3', '%4'] }

Special instruction forms: C<label> (code location), C<jmp> (unconditional jump), C<cond_br> (conditional branch with
true/false labels).

Provides virtual register allocation (C<new_reg>), label generation (C<new_label>), and IR dump (C<dump_ir>).

=head1 METHODS

=head2 emit($op, $type, $args, $dest?)

Appends an instruction. Auto-generates a destination vreg if C<$type> is not C<void> and C<$dest> is undef.

=head2 emit_label($name)

TODO

=head2 emit_jump($label)

TODO

=head2 emit_cond_br($reg, $true_label, $false_label)

TODO

=head2 dump_ir($title?)

Prints every instruction to stdout for debugging.

=cut
