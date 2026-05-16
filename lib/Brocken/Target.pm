package Brocken::Target {
    use v5.40;
    use feature 'class';
    no warnings 'experimental::class';

    class Brocken::Target {
        field $os   : param : reader;
        field $arch : param : reader;
        method registers()                                        { die "Abstract" }
        method emit_op( $as, $inst, $reg_map, $driver )           { die "Abstract" }
        method compile_intrinsic( $as, $inst, $reg_map, $driver ) { die "Abstract" }

        method val( $reg_map, $arg ) {
            return undef unless defined $arg;
            return $reg_map->{$arg} if !ref($arg) && $arg =~ /^%/;
            return $arg;
        }
        method new_assembler() { die "Abstract" }
    }
}
1;
__END__

=pod

=head1 NAME

Brocken::Target - Abstract base class for CPU target code generation

=head1 DESCRIPTION

Defines the interface for CPU-specific target modules (X64, ARM64). Subclasses implement C<emit_op> for
IR-to-machine-code mapping and C<registers> for the allocatable register pool.

Provides a C<val> helper for resolving virtual register names to physical registers via the register map.

=head1 METHODS

=head2 registers

Abstract. Returns the list of allocatable callee-saved physical registers.

=head2 emit_op($as, $inst, $reg_map, $driver)

Abstract. Emits machine code for a single non-intrinsic IR instruction.

=head2 compile_intrinsic($as, $inst, $reg_map, $driver)

Abstract. Emits machine code for intrinsic_* IR instructions.

=head2 val($reg_map, $arg)

If C<$arg> is a virtual register (starts with C<%>), resolves it to a physical register via C<$reg_map>. Otherwise
returns C<$arg> as-is (an immediate value).

=cut
}

1;
