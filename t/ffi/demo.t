use v5.40;
use lib 'lib';
use Brocken::TestHelpers qw[test_brocken];
use Test2::V0;
use Path::Tiny;
#
my $c    = path($0)->sibling('demolib.c')->absolute;
my $so   = path($0)->sibling('demolib.c')->absolute;
my $lib  = path($0)->sibling( $^O eq 'MSWin32' ? 'demolib.dll' : 'libdemo.so' )->absolute;
my $libc = $^O eq 'MSWin32' ? 'msvcrt.dll' : 'libc.so.6';
system( 'gcc', '-shared', '-o', $lib, '-fPIC', $c ) == 0 or die "gcc failed: $?";

# On Windows, libc's puts buffers output separately from Brocken's say (which uses WriteFile directly).
# The C constructor in demolib.c cannot flush msvcrt.dll's separate CRT buffer, so puts output
# only appears at program exit, after all Brocken say output.
my @ffi_expected = ( $^O eq 'MSWin32' )
    ? (   # Windows: CRT buffered output arrives at exit, after Brocken's direct output
        '--- Part 1: Standard libc FFI ---',
        '--- Part 2: Custom Shared Library FFI ---',
        '42',
        'Hello, Brocken Compiler from C!',
        'Hello from standard libc puts!',
    )
    : (   # Unix: shared CRT, constructor sets _IONBF, output arrives in program order
        '--- Part 1: Standard libc FFI ---',
        '--- Part 2: Custom Shared Library FFI ---',
        'Hello from standard libc puts!',
        '42',
        'Hello, Brocken Compiler from C!',
    );
test_brocken(
    name     => 'C FFI',
    source   => qq{
        # 1. Wrap standard libc puts from the correct platform library
        native "$libc", "puts", "(String)->Int";

        # 2. Wrap our custom compiled shared library
        native "$lib", "add", "(Int, Int)->Int";
        native "$lib", "hello", "(String)->void";

        say "--- Part 1: Standard libc FFI ---";
        puts("Hello from standard libc puts!");

        say "--- Part 2: Custom Shared Library FFI ---";
        my Int \$sum = add(40, 2);
        say \$sum;  # Outputs: 42

        hello("Brocken Compiler");
     },
    expected => \@ffi_expected,
);
done_testing;
