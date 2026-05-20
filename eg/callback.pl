# Demonstrates passing a Perl callback to a Brocken function and having
# Brocken call back into Perl, using shared library interop via Affix.
use v5.40;
use lib '../lib';
use Brocken::Compiler;
use Affix;
$|++;
my $source = <<'BROCKEN';
# Brocken accepts a callback and an integer
sub map_value(Callback[[Int] => Int] $cb, Int $val) {
    say "   [Brocken] Received value: " . $val;
    say "   [Brocken] Calling Perl callback...";

    my $result = $cb->($val);

    say "   [Brocken] Perl returned: " . $result;
    return $result;
}
BROCKEN
my $ext      = $^O eq 'MSWin32' ? '.dll' : ( $^O eq 'darwin' ? '.dylib' : '.so' );
my $lib_name = "./demo_cb$ext";
say "Compiling $lib_name...";
my $compiler = Brocken::Compiler->new( type => 'shared' );
$compiler->compile_source( $source, $lib_name );
say "Binding to Affix...";
warn `nm -D $lib_name`;
warn `objdump -p $lib_name`;
warn affix $lib_name, 'map_value', [ Callback [ [Int] => Int ], Int ] => Int;
say "Executing...";

# The Perl callback to pass into Brocken
my $perl_callback = sub {
    my $v = shift;
    say "      [Perl] Callback triggered with $v. Multiplying by 10!";
    return $v * 10;
};

# Note: Because of Brocken's Smi tagging on the return value of map_value,
# we untag the final result in Perl (result >> 1)
my $tagged_result = map_value( $perl_callback, 42 );
my $actual_result = $tagged_result >> 1;
say "Final Result back in Perl: $actual_result";
