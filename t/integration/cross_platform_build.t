use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib', '../../lib';
use Brocken::Compiler::Pipeline;

my @matrix = (
    # x64 support
    map( { [ $_, 'x64' ] } qw(win64 linux freebsd openbsd netbsd dragonfly macos) ),

    # arm64 support
    map( { [ $_, 'arm64' ] } qw(win64 linux freebsd openbsd netbsd dragonfly macos) ),

    # riscv64 support
    [ 'linux', 'riscv64' ],
);

for my $pair (@matrix) {
    my ( $os, $arch ) = @$pair;
    subtest "OS: $os, Arch: $arch" => sub {
        my $compiler;
        my $success = eval {
            $compiler = Brocken::Compiler::Pipeline->new( os => $os, arch => $arch );
            $compiler->compile_source( 'say 1;', 'test', 'test.brocken' );
            1;
        };
        ok( $success, "Compiler init/compile succeeded for $os/$arch" . ( $@ ? ": $@" : '' ) )
            or diag( "Error: $@" );
        unlink 'test.exe', 'test';    # Cleanup potential output files
    };
}

done_testing();
