use v5.40;
use lib 'lib', '../../lib';
use Test2::V0;

BEGIN {
    eval { require Affix; Affix->import(); 1 } or plan skip_all => "Affix not available";
}
use Brocken;
use Brocken::Compiler::Pipeline;
use Brocken::Compiler::DataSegment;
use Brocken::Compiler::Lowering;
use Brocken::Compiler::Optimizer;
use Brocken::Codegen;
use Brocken::Host;
#
subtest 'Float type parsing' => sub {
    my $source = 'sub test_float(Float $x) { return $x; }';
    my $tokens = Brocken::Core::Lexer->new( source => $source )->lex();
    my $ast    = Brocken::Core::Parser->new( tokens => $tokens )->parse();
    ok( $ast, 'Float type parses correctly' );
};
subtest 'Float DLL generation with XMM ABI' => sub {

    # Simple pass-through first to verify basic Float handling
    my $source = <<'BROCKEN';
sub pass_float(Float $x) {
    say 'The value of $x: '. $x;
    return $x+1;
}
BROCKEN
    my $target_os = Brocken::Host::os();
    my $arch      = Brocken::Host::arch();
    my $out_ext   = $^O eq 'MSWin32' ? '.dll' : '.so';
    my $out_name  = "test_float${out_ext}";
    my $out_file  = ( $^O eq 'MSWin32' ? '' : './' ) . $out_name;
    my $tokens    = Brocken::Core::Lexer->new( source => $source )->lex();
    my $ast       = Brocken::Core::Parser->new( tokens => $tokens )->parse();
    my $driver    = Brocken::Compiler::Pipeline->new( os => $target_os, arch => $arch, type => 'shared', debug => 0 );
    my $ds        = Brocken::Compiler::DataSegment->new();
    my $lowering  = Brocken::Compiler::Lowering->new( driver => $driver, data_segment => $ds );
    $lowering->set_skip_runtime(1);
    $lowering->lower_program($ast);
    my $optimizer = Brocken::Compiler::Optimizer->new();
    $optimizer->optimize( $lowering->builder );
    my $format = $driver->format;
    my $data   = $ds->raw_data();
    $format->pre_layout( 65536, length($data), $arch, $target_os );
    my $codegen = Brocken::Codegen->new( arch => $arch );
    my @insts   = $lowering->builder->instructions;
    $codegen->compile( \@insts, $driver );
    my $as = $driver->as;
    $as->resolve( $driver->text_rva, $driver->data_rva );
    my $all_labels = $as->labels;
    $format->set_labels($all_labels);
    my @exports = sort(qw(pass_float));
    $format->set_exported_funcs( \@exports );
    my $text = $as->code;
    $format->write_bin( $out_name, $text, $data, $arch, $target_os, 'shared' );
    ok( -f $out_name, 'Float shared library generated with XMM ABI' );

    # Test Float pass-through
    affix $out_file, 'pass_float', [Float] => Float;
    my $result = pass_float(3.14);
    is $result, float( 4.14, tolerance => 0.01 ), 'pass/return floats';
    unlink $out_name if -f $out_name;
};
done_testing();
