use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';

class Brocken::IR::Builder {
    field @instructions : reader;
    field $reg_count   = 0;
    field $label_count = 0;
    method new_reg()               { return "%" . ++$reg_count; }
    method new_label()             { return "L" . ++$label_count; }
    method set_instructions(@inst) { @instructions = @inst }

    method emit( $op, $type, $args, $dest = undef ) {
        $dest //= $self->new_reg();
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
                @al = map {
                    if    ( !defined($_) )               {"undef"}
                    elsif ( ref($_) && $_->can('dump') ) { $_->dump }
                    elsif ( ref($_) )                    { "OBJ(" . ref($_) . ")" }
                    else                                 {$_}
                } @{ $i->{args} };
            }
            elsif ( $i->{target} ) { push @al, "target:" . $i->{target}; }
            elsif ( $i->{name} )   { push @al, "name:" . $i->{name}; }
            elsif ( $i->{op} eq 'cond_br' ) {
                push @al, "reg:" . $i->{reg} . " true:" . $i->{true_l} . " false:" . $i->{false_l};
            }
            my $args = join( ', ', @al );
            say sprintf( "  %-3s %-15s %-5s [%s]", ( $dest ? $dest : "" ), $op, ( $i->{type} // "" ), $args );
        }
    }
};
1;
