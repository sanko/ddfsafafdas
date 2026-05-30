use v5.40;
use lib 'lib';
use Test2::V0;
use File::Temp qw(tempdir);
use File::Spec;
use Brocken::Compiler::Pipeline;

# 1. Define the Brocken Shared Library Source Code
my $lib_source = q{
    sub add(Int $a, Int $b) {
        return $a + $b;
    }

    sub multiply(Int $a, Int $b) {
        return $a * $b;
    }
};
my $dir          = tempdir( CLEANUP => 1 );
my $lib_ext      = $^O eq 'MSWin32' ? '.dll' : '.so';
my $lib_prefix   = $^O eq 'MSWin32' ? ''     : 'lib';
my $lib_filename = File::Spec->catfile( $dir, "${lib_prefix}brockenlib${lib_ext}" );

# Normalize Windows backslashes to forward slashes for Brocken string safety
$lib_filename =~ s{\\}{/}g;
my $compiler_lib = Brocken::Compiler::Pipeline->new( type => 'shared', arch => 'x64', os => $^O eq 'MSWin32' ? 'win64' : 'linux', debug => 1 );
eval { $compiler_lib->compile_source( $lib_source, $lib_filename ); };
if ( my $err = $@ ) {
    bail_out("Shared library compilation failed: $err");
}
ok( -f $lib_filename, "Shared library compiled successfully to $lib_filename" );

# 2. Define the Main Brocken Program Source Code
# This program dynamically loads our Brocken shared library and calls its functions
my $main_source = qq{
    native "$lib_filename", "add", "(Int, Int)->Int";
    native "$lib_filename", "multiply", "(Int, Int)->Int";

    say "--- Brocken Shared Library FFI Test ---";
    my Int \$sum = add(100, 24);
    say "Sum: " . \$sum;

    my Int \$prod = multiply(6, 7);
    say "Product: " . \$prod;
};
my $exe_filename = File::Spec->catfile( $dir, "test_main" . ( $^O eq 'MSWin32' ? '.exe' : '' ) );
$exe_filename =~ s{\\}{/}g;
my $compiler_main = Brocken::Compiler::Pipeline->new( type => 'exe', arch => 'x64', os => $^O eq 'MSWin32' ? 'win64' : 'linux', debug => 1 );
eval { $compiler_main->compile_source( $main_source, $exe_filename ); };
if ( my $err = $@ ) {
    bail_out("Main program compilation failed: $err");
}
ok( -f $exe_filename, "Main program compiled successfully to $exe_filename" );

# 3. Execute the Main Program and Verify Output
my $run = $exe_filename;
if ( $^O ne 'MSWin32' && $exe_filename !~ m{^/} && $exe_filename !~ m{^\./} ) {
    $run = './' . $exe_filename;
}
my $output    = `"$run" 2>&1`;
my $exit_code = $?;
is( $exit_code, 0, "Main program executed with exit code 0" );
my @lines = split( /\n/, $output );
map {s/\r//g} @lines;    # Strip Windows carriage returns
diag $output;
is( $lines[0], "--- Brocken Shared Library FFI Test ---", "Output Line 1: Header" );
is( $lines[1], "Sum: 124",                                "Output Line 2: Sum calculated in shared library" );
is( $lines[2], "Product: 42",                             "Output Line 3: Product calculated in shared library" );
done_testing;
