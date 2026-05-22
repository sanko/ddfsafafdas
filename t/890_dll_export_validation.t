use v5.40;
use lib 'lib';
use Test::More;
use File::Temp qw(tempfile);
use FFI::ExtractSymbols;
require Brocken;

my ( $tmp_fh, $dll ) = tempfile( UNLINK => 1, SUFFIX => '.dll' );
close $tmp_fh;

my $source = <<'BROCKEN';
sub add(Int $x, Int $y) {
    return $x + $y;
}
BROCKEN

my $compiler = Brocken::Compiler->new( type => 'shared', os => 'win64', arch => 'x64' );
eval { $compiler->compile_source( $source, $dll ); };
if ( my $err = $@ ) {
    BAIL_OUT("compilation failed: $err");
}
ok( -f $dll, "DLL generated" );

my @exports;
FFI::ExtractSymbols::extract_symbols( $dll, export => sub { push @exports, $_[0] } );
ok( grep { $_ eq 'add' } @exports, "Exported 'add' found in DLL" );

done_testing();
