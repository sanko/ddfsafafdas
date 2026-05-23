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
subtest 'Struct type parsing' => sub {
    my $source = 'sub test_struct(Struct $s) { return $s; }';
    my $tokens = Brocken::Lexer->new( source => $source )->lex();
    my $ast    = Brocken::Parser->new( tokens => $tokens )->parse();
    ok( $ast, 'Struct type parses correctly' );
};
subtest 'Struct pass-through in DLL' => sub {
    my $target_os = $^O eq 'MSWin32' ? 'win64' : 'linux';
    my $out_ext   = $^O eq 'MSWin32' ? '.dll' : '.so';
    my $out_name  = "test_struct${out_ext}";
    my $source = <<'BROCKEN';
sub pass_struct(Struct $s) {
    return $s;
}

sub get_null() {
    return 0;
}
BROCKEN
    my $tokens   = Brocken::Lexer->new( source => $source )->lex();
    my $ast      = Brocken::Parser->new( tokens => $tokens )->parse();
    my $driver   = Brocken::Compiler->new( os => $target_os, arch => 'x64', type => 'shared', debug => 0 );
    my $ds       = Brocken::Compiler::DataSegment->new();
    my $lowering = Brocken::Compiler::Lowering->new( driver => $driver, data_segment => $ds );
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
    my @exports = sort(qw(pass_struct get_null));
    $format->set_exported_funcs( \@exports );
    my $text    = $as->code;
    $format->write_bin( $out_name, $text, $data, 'x64', $target_os, 'shared' );
    ok( -f $out_name, 'Struct shared library generated' );
    pass('Struct type parameters parsed and shared library generated');
    unlink $out_name if -f $out_name;
};
done_testing();
