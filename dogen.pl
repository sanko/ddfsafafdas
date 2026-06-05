use v5.40;
use feature 'class';
use lib 'lib';
use Brocken::Compiler::Pipeline;
my $p = Brocken::Compiler::Pipeline->new( arch => 'arm64', os => 'win64' );
$p->compile_source( 'say 42', 'test_arm64.bin' );
