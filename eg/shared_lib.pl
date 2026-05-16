use v5.40;
use lib '../lib';
use Brocken::Compiler;
use Affix;
$|++;
my $source = <<'BROCKEN';
sub calculate_hypotenuse(Float $a, Float $b) {
    # Using a simple math operation for the demo
    return ($a * $a) + ($b * $b);
}
BROCKEN

# Determine the correct shared library extension for the host OS
my $ext      = $^O eq 'MSWin32' ? '.dll' : ( $^O eq 'darwin' ? '.dylib' : '.so' );
my $lib_name = "./demo_math$ext";
say "Compiling $lib_name...";
my $compiler = Brocken::Compiler->new( type => 'shared' );
$compiler->compile_source( $source, $lib_name );
say "Binding to Affix...";

# Bind the Brocken 'calculate_hypotenuse' function to Perl
affix( $lib_name, 'calculate_hypotenuse', [ Double, Double ] => Double );
say "Calling from Perl...";
my $a         = 3.0;
my $b         = 4.0;
my $c_squared = calculate_hypotenuse( $a, $b );
say "The hypotenuse squared of $a and $b is $c_squared";
