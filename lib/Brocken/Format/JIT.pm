package Brocken::Format::JIT {
    use v5.40;
    use feature 'class';
    no warnings 'experimental::class';
    use Brocken::Format;

    class Brocken::Format::JIT : isa(Brocken::Format) {
        our %IMPORTS = (
            ExitProcess                 => 0,
            GetStdHandle                => 8,
            WriteFile                   => 16,
            VirtualAlloc                => 24,
            SetConsoleOutputCP          => 32,
            AddVectoredExceptionHandler => 40,
            CreateEventA                => 48,
            SetEvent                    => 56,
            WaitForSingleObject         => 64,
            CloseHandle                 => 72,
            CreateFileA                 => 80,
            ReadFile                    => 88,
            GetFileSizeEx               => 96
        );

        method import_rva($n) {
            return $self->rva_for('.idata') + ( $IMPORTS{$n} // die "Unknown JIT import: $n" );
        }

        method _setup_layout( $l, $t, $d, $a, $o, $dbg = 0 ) {
            $l->add_section( '.text',  $t,                    0x60000020 );
            $l->add_section( '.data',  ( $d > 0 ? $d : 512 ), 0xC0000040 );
            $l->add_section( '.idata', 2048,                  0xC0000040 );
        }

        method write_bin( $filename, $text, $data, $arch, $os, $type ) {
            # No-op or return raw data for JIT
            return "";
        }
    }
}
1;
__END__

=pod

=head1 NAME

Brocken::Format::JIT - Binary format subclass for in-memory JIT execution

=head1 DESCRIPTION

Implements standard section layouts (.text, .data, .idata) in-memory for the JIT engine.

=cut
