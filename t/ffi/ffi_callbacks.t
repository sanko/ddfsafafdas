use v5.40;
use lib 'lib';
use Brocken::TestHelpers qw(test_brocken);
use Test2::V0;
$^O eq 'MSWin32' or plan skip_all => 'Windows-only test';
test_brocken(
    name   => 'Dynamic Windows callbacks with our variables',
    source => q{
        # Bind to standard Win32 User APIs
        native "user32.dll", "EnumWindows", "(Pointer, Int)->Bool";
        my Int $total = 0;
        my Any $cb = make_callback(sub (Int $hwnd, Int $lparam) {
            $total = $total + 1;
            return 1; # Return True to C to continue enumeration
        }, "(Int, Int)->Int");

        EnumWindows($cb, 0);

        say "Enumerated windows successfully. Total: " . $total;
    },
    expected => qr/Enumerated windows successfully\. Total: \d+/
);
done_testing;
