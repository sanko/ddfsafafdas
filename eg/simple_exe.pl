use v5.40;
use lib '../lib';
use Brocken::Compiler;
#
my $source = <<'BROCKEN';
my $i = 0;
while ($i < 5) {
    say "Hello from Brocken native executable! i = " . $i;
    $i = $i + 1;
}
BROCKEN
my $os       = $^O eq 'MSWin32' ? 'win64' : 'linux';
my $ext      = $os eq 'win64'   ? '.exe'  : '';
my $exe_name = "demo_exe$ext";
say "Compiling $exe_name...";
my $compiler = Brocken::Compiler->new( type => 'exe', debug => 4 );
$compiler->compile_source( $source, $exe_name );
#
say "Running $exe_name...\n" . ( "-" x 30 );
system( ( $os eq 'win64' ? '' : './' ) . $exe_name );
