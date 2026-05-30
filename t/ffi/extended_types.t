use v5.40;
use lib 'lib';
use Brocken::TestHelpers qw(test_brocken);
use Test2::V0;

# Test extended FFI types (Float/double, Pointers)
if ( $^O eq 'MSWin32' ) {
    test_brocken(
        name   => 'FFI Math Functions (doubles/Floats)',
        source => q{
            native "msvcrt.dll", "pow", "(double, double)->double";
            native "msvcrt.dll", "sin", "(double)->double";

            my Float $base = 2.0;
            my Float $exp  = 3.0;
            my Any $res  = pow($base, $exp);
            say "2.0 ^ 3.0 = " . $res;

            my Any $s = sin(0.0);
            say "sin(0.0) = " . $s;
            },
        expected => [ "2.0 ^ 3.0 = [Float]", "sin(0.0) = [Float]" ]
    );
    test_brocken(
        name   => 'FFI Memory Management (Pointers)',
        source => q{
            native "msvcrt.dll", "malloc", "(Int)->Pointer";
            native "msvcrt.dll", "free", "(Pointer)->void";

            my Any $ptr = malloc(1024);
            say "Allocated 1024 bytes.";

            # free returns void
            free($ptr);
            say "Freed memory.";        },
        expected => [ "Allocated 1024 bytes.", "Freed memory." ]
    );
}
else {
    # Generic Unix-like targets (Linux/macOS)
    test_brocken(
        name   => 'FFI Math Functions (doubles/Floats) - Unix',
        source => q{
            native "libm.so.6", "pow", "(double, double)->double";
            native "libm.so.6", "sin", "(double)->double";

            my Float $base = 2.0;
            my Float $exp  = 3.0;
            my Float $res  = pow($base, $exp);
            say "2.0 ^ 3.0 = " . $res;

            my Float $s = sin(0.0);
            say "sin(0.0) = " . $s;
        },
        expected => [ "2.0 ^ 3.0 = [Float]", "sin(0.0) = [Float]" ]
    );
}
done_testing;
