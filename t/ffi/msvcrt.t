use v5.40;
use lib 'lib', '../../lib';
use Brocken::TestHelpers qw(test_brocken);
use Test2::V0;
test_brocken(
    name   => 'C FFI via msvcrt.dll (puts and strlen)',
    source => q{
        # Bind dynamically to the Windows C Runtime
        native "msvcrt.dll", "puts", "(String)->Int";
        native "msvcrt.dll", "strlen", "(String)->Int";

        my String $str = "Hello directly from the C runtime!";

        # Brocken strings have an invisible object header, but the FFI unboxes them
        # perfectly so `strlen` sees a standard null-terminated C string!
        my Int $len = strlen($str);

        # Puts prints to standard output and returns a positive integer
        my Int $status = puts($str);

        say "Brocken String Length: " . $len;
    },
    expected => qr[Brocken String Length: 34\r?\nHello directly from the C runtime!]
);
done_testing;
