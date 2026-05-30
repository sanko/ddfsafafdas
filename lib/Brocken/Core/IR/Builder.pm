package Brocken::Core::IR::Builder;
use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';

class Brocken::Core::IR::Builder {
    field $_instructions : reader = [];
    field $reg_count              = 0;
    field $label_count            = 0;
    method new_reg()               { return '%' . ++$reg_count; }
    method new_label()             { return 'L' . ++$label_count; }
    method set_instructions(@inst) { $_instructions = [@inst] }
    method push_instruction($inst) { push @$_instructions, $inst }
    method pop_instruction()       { pop @$_instructions }
    method last_instruction()      { $_instructions->[-1] }
    method instructions()          { wantarray ? @$_instructions : $_instructions }

    method emit( $op, $type, $args, $dest = undef ) {
        if ( !defined($dest) && $type ne 'void' ) { $dest = $self->new_reg(); }
        push @$_instructions, { op => $op, type => $type, dest => $dest, args => $args };
        return $dest;
    }
    method emit_label($name) { push @$_instructions, { op => 'label', name   => $name }; }
    method emit_jump($label) { push @$_instructions, { op => 'jmp',   target => $label }; }
    method emit_cond_br( $reg, $tl, $fl ) { push @$_instructions, { op => 'cond_br', reg => $reg, true_l => $tl, false_l => $fl }; }

    method dump_ir ( $title //= () ) {
        say "\n=== $title ===" if $title;
        for my $i (@$_instructions) {
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

Brocken::Core::IR::Builder - Linear intermediate representation builder

=head1 SYNOPSIS

    my $builder = Brocken::Core::IR::Builder->new();
    my $v1 = $builder->emit('constant', 'i64', [10]);
    my $v2 = $builder->emit('constant', 'i64', [20]);
    my $res = $builder->emit('add', 'i64', [$v1, $v2]);
    $builder->emit('leave_func', 'void', [$res]);

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

Appends a label instruction to the IR sequence.

=head2 emit_jump($label)

Appends an unconditional jump instruction to the IR sequence.

=head2 emit_cond_br($reg, $true_label, $false_label)

Appends a conditional branch instruction. Jumps to C<$true_label> if C<$reg> is non-zero (true), otherwise jumps to
C<$false_label>.

=head2 dump_ir($title?)

Prints every instruction to stdout for debugging.

=cut

