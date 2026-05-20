use v5.40;
use lib '../lib';
use Carp::Always;
use Brocken::Compiler;
$|++;
my $source = <<'BROCKEN';
class Point {
    field $x;
    field $y;
}

my $p = Point->new();
$p->x = "Hello";
$p->y = "World";

if ($p->x eq "Hello") {
    say "String ops and class accessors work!";
}

my $h = { test => 123 };
if (exists $h{"test"}) {
    say "Hash exists works!";
    delete $h{"test"};
}

if (!(exists $h{"test"})) {
    say "Hash delete works!";
}
BROCKEN
my $os       = $^O eq 'MSWin32' ? 'win64' : 'linux';
my $ext      = $os eq 'win64'   ? '.exe'  : '';
my $exe_name = "test_features$ext";
say "Compiling $exe_name...";
my $compiler = Brocken::Compiler->new( type => 'exe', debug => 4 );
$compiler->compile_source( $source, $exe_name );
say "Running $exe_name...\n" . ( "-" x 30 );
system( ( $os eq 'win64' ? '' : './' ) . $exe_name );
__END__
use v5.40;
use lib '../lib';
use Carp::Always;
use Brocken::Compiler;
$|++;
my $source = <<'BROCKEN';
my $data = { key => 10, key2 => 'Hi' };
say $data{keyX} . '?';
say $data{key2};
delete $data{key2};
say $data{key2};
BROCKEN
my $os       = $^O eq 'MSWin32' ? 'win64' : 'linux';
my $ext      = $os eq 'win64'   ? '.exe'  : '';
my $exe_name = "test_gc_multi$ext";
say "Compiling $exe_name...";
my $compiler = Brocken::Compiler->new( type => 'exe', debug => 4 );
$compiler->compile_source( $source, $exe_name );
#
say "Running $exe_name...\n" . ( "-" x 30 );
system( q[gdb -batch -ex "run" -ex "bt" -ex "x/i $pc" -ex "info registers" -ex "disas" ] . ( $os eq 'win64' ? '' : './' ) . $exe_name );
