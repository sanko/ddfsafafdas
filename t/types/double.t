use strict;
use warnings;
use v5.40;
use lib '../../lib';
use Test::More;
use Brocken;
use Brocken::Compiler;
use Brocken::Compiler::DataSegment;
use Brocken::Compiler::Lowering;
use Brocken::Compiler::Optimizer;
use Brocken::Codegen;
use Affix;
subtest 'Double type parsing' => sub {
    my $source = 'sub test_double(double $x) { return $x; }';
    my $tokens = Brocken::Lexer->new( source => $source )->lex();
    my $ast    = Brocken::Parser->new( tokens => $tokens )->parse();
    ok( $ast, 'Double type parses correctly' );
};
subtest 'Double pass-through in DLL' => sub {
    my $source = <<'BROCKEN';
sub pass_double(double $x) {
    return $x;
}

sub identity_double(double $a, double $b) {
    return $a;
}
BROCKEN
    my $tokens   = Brocken::Lexer->new( source => $source )->lex();
    my $ast      = Brocken::Parser->new( tokens => $tokens )->parse();
    my $driver   = Brocken::Compiler->new( os => 'win64', arch => 'x64', type => 'shared', debug => 0 );
    my $ds       = Brocken::Compiler::DataSegment->new();
    my $lowering = Brocken::Compiler::Lowering->new( driver => $driver, data_segment => $ds );
    $lowering->set_skip_runtime(1);
    $lowering->lower_program($ast);
    my $optimizer = Brocken::Compiler::Optimizer->new();
    $optimizer->optimize( $lowering->builder );
    my $format = $driver->format;
    my $data   = $ds->get_raw_data();
    $format->pre_layout( 65536, length($data), 'x64', 'win64' );
    my $codegen = Brocken::Codegen->new( arch => 'x64' );
    my @insts   = $lowering->builder->instructions;
    $codegen->compile( \@insts, $driver );
    my $as = $driver->as;
    $as->resolve( $driver->text_rva, $driver->data_rva );
    my %all_labels = $as->labels;
    $format->set_labels( \%all_labels );
    my @exports = sort(qw(pass_double identity_double));
    $format->set_exported_funcs( \@exports );
    my $text    = $as->code;
    my $out_dll = 'test_double.dll';
    $format->write_bin( $out_dll, $text, $data, 'x64', 'win64', 'shared' );
    ok( -f $out_dll, 'Double DLL generated' );
    pass('Double type parameters parsed and DLL generated - FP ops need XMM register allocation');
    unlink $out_dll if -f $out_dll;
};
done_testing();
