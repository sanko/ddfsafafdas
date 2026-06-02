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
#
subtest 'Double type parsing' => sub {
    my $source = 'sub test_double(Double $x) { return $x; }';
    my $tokens = Brocken::Core::Lexer->new( source => $source )->lex();
    my $ast    = Brocken::Core::Parser->new( tokens => $tokens )->parse();
    ok( $ast, 'Double type parses correctly' );
};
subtest 'Double DLL generation with XMM ABI' => sub {

    # Simple pass-through first to verify basic Double handling
    my $source = <<'BROCKEN';
sub pass_double(Double $x) {
    say 'The value of $x: '. $x;
    return $x + 1;
}
BROCKEN
    my $target_os = $^O eq 'MSWin32' ? 'win64' : 'linux';
    my $out_ext   = $^O eq 'MSWin32' ? '.dll'  : '.so';
    my $out_name  = "test_double${out_ext}";
    my $out_file  = ( $^O eq 'MSWin32' ? '' : './' ) . $out_name;
    my $tokens    = Brocken::Core::Lexer->new( source => $source )->lex();
    my $ast       = Brocken::Core::Parser->new( tokens => $tokens )->parse();
    my $driver    = Brocken::Compiler::Pipeline->new( os => $target_os, arch => 'x64', type => 'shared', debug => 0 );
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
    my @exports = sort(qw(pass_double));
    $format->set_exported_funcs( \@exports );
    my $text = $as->code;
    $format->write_bin( $out_name, $text, $data, 'x64', $target_os, 'shared' );
    ok( -f $out_name, 'Double shared library generated with XMM ABI' );

    # Test Double pass-through
    affix $out_file, 'pass_double', [Double] => Double;
    my $result = pass_double(3.14);
    is $result, float( 4.14, tolerance => 0.01 ), 'pass/return doubles';
    unlink $out_name if -f $out_name;
};
done_testing();
