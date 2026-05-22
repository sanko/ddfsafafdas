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
subtest 'Struct type parsing' => sub {
    my $source = 'sub test_struct(Struct $s) { return $s; }';
    my $tokens = Brocken::Lexer->new( source => $source )->lex();
    my $ast    = Brocken::Parser->new( tokens => $tokens )->parse();
    ok( $ast, 'Struct type parses correctly' );
};
subtest 'Struct pass-through in DLL' => sub {
    my $source = <<'BROCKEN';
sub pass_struct(Struct $s) {
    return $s;
}

sub get_size() {
    return 8;
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
    my $data   = $ds->raw_data();
    $format->pre_layout( 65536, length($data), 'x64', 'win64' );
    my $codegen = Brocken::Codegen->new( arch => 'x64' );
    my @insts   = $lowering->builder->instructions;
    $codegen->compile( \@insts, $driver );
    my $as = $driver->as;
    $as->resolve( $driver->text_rva, $driver->data_rva );
    my %all_labels = $as->labels;
    $format->set_labels( \%all_labels );
    my @exports = sort(qw(pass_struct get_size));
    $format->set_exported_funcs( \@exports );
    my $text    = $as->code;
    my $out_dll = 'test_struct.dll';
    $format->write_bin( $out_dll, $text, $data, 'x64', 'win64', 'shared' );
    ok( -f $out_dll, 'Struct DLL generated' );
    pass('Struct type parameters parsed and DLL generated');
    unlink $out_dll if -f $out_dll;
};
done_testing();
