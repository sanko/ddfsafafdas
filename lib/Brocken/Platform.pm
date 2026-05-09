package Brocken::Platform {
    use v5.40;
    use feature 'class';
    no warnings 'experimental::class';

    class Brocken::Platform {
        field $os : param : reader;
        method format_name()                                            {...}
        method shadow_space()                                           {0}
        method emit_intrinsic( $target, $as, $inst, $reg_map, $driver ) {...}
    }
}
1;
__END__

=pod

=head1 NAME

Brocken::Platform - Abstract base class for OS platform intrinsics

=head1 DESCRIPTION

Defines the interface for OS-specific intrinsic functions. Subclasses implement OS-level operations like memory
allocation, I/O, and process exit, as well as architecture-dependent routines like fiber context switching.

=head1 METHODS

=head2 format_name

Returns the binary format name ('PE', 'ELF').

=head2 shadow_space

Returns the shadow space size required by the ABI (32 for Windows x64, 0 for SysV).

=head2 emit_intrinsic($target, $as, $inst, $reg_map, $driver)

Emits machine code for intrinsic_* IR instructions.

=cut
}
1;
