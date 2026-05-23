use v5.40;
use lib 'lib';
use Brocken::TestHelpers qw(test_brocken);
use Test2::V0;
use File::Basename;
use File::Spec;
my $t_dir = File::Spec->rel2abs('t/ffi');
# On Linux, dlopen requires a directory slash (like ./) to load from the current directory
my $lib  = $^O eq 'MSWin32' ? 'demolib.dll' : './libdemo.so';
my $libc = $^O eq 'MSWin32' ? 'msvcrt.dll'  : 'libc.so.6';
system( 'gcc', '-shared', '-o', $lib, '-fPIC', File::Spec->catfile( $t_dir, 'demolib.c' ) ) == 0 or die "gcc failed: $?";
test_brocken(
    name   => 'C FFI',
    source => qq{
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
    expected => [
        '--- Part 1: Standard libc FFI ---',
        '--- Part 2: Custom Shared Library FFI ---',
        '42',
        'Hello, Brocken Compiler from C!',
        'Hello from standard libc puts!'
    ]
);
done_testing;
