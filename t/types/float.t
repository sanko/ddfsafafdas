use strict;
use warnings;
use v5.40;
use lib 'lib';
use Test::More;
use Affix;
use Brocken;
use Brocken::Compiler;
use Brocken::Compiler::DataSegment;
use Brocken::Compiler::Lowering;
use Brocken::Compiler::Optimizer;
use Brocken::Codegen;
subtest 'Float type parsing' => sub {
    my $source = 'sub test_float(Float $x) { return $x; }';
    my $tokens = Brocken::Lexer->new( source => $source )->lex();
    my $ast    = Brocken::Parser->new( tokens => $tokens )->parse();
    ok( $ast, 'Float type parses correctly' );
};
subtest 'Float DLL generation with XMM ABI' => sub {

    # Simple pass-through first to verify basic Float handling
    my $source = <<'BROCKEN';
sub pass_float(Float $x) {
    return $x;
}
BROCKEN
    my $target_os = $^O eq 'MSWin32' ? 'win64' : 'linux';
    my $out_ext   = $^O eq 'MSWin32' ? '.dll'  : '.so';
    my $out_name  = "test_float${out_ext}";
    my $out_file  = ( $^O eq 'MSWin32' ? '' : './' ) . $out_name;
    my $tokens    = Brocken::Lexer->new( source => $source )->lex();
    my $ast       = Brocken::Parser->new( tokens => $tokens )->parse();
    my $driver    = Brocken::Compiler->new( os => $target_os, arch => 'x64', type => 'shared', debug => 0 );
    my $ds        = Brocken::Compiler::DataSegment->new();
    my $lowering  = Brocken::Compiler::Lowering->new( driver => $driver, data_segment => $ds );
    $lowering->set_skip_runtime(1);
    $lowering->lower_program($ast);
    my $optimizer = Brocken::Compiler::Optimizer->new();
    $optimizer->optimize( $lowering->builder );
    my $format = $driver->format;
    my $data   = $ds->raw_data();
    $format->pre_layout( 65536, length($data), 'x64', $target_os );
    my $codegen = Brocken::Codegen->new( arch => 'x64' );
    my @insts   = $lowering->builder->instructions;
    $codegen->compile( \@insts, $driver );
    my $as = $driver->as;
    $as->resolve( $driver->text_rva, $driver->data_rva );
    my $all_labels = $as->labels;
    $format->set_labels($all_labels);
    my @exports = sort(qw(pass_float));
    $format->set_exported_funcs( \@exports );
    my $text = $as->code;
    $format->write_bin( $out_name, $text, $data, 'x64', $target_os, 'shared' );
    ok( -f $out_name, 'Float shared library generated with XMM ABI' );

    # Test Float pass-through
    use Affix;
    affix $out_file, 'pass_float', [Float] => Float;
    my $result = pass_float(3.14);
    cmp_ok( abs( $result - 3.14 ), '<', 0.01, 'Float pass-through: 3.14' );
    unlink $out_name if -f $out_name;
};
done_testing();
