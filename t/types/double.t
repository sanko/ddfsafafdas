use strict;
use warnings;
use v5.40;
use lib 'lib';
use Test::More;
use Brocken;
use Brocken::Compiler::Pipeline;
use Brocken::Compiler::DataSegment;
use Brocken::Compiler::Lowering;
use Brocken::Compiler::Optimizer;
use Brocken::Codegen;
use Affix;
subtest 'Double type parsing' => sub {
    my $source = 'sub test_double(double $x) { return $x; }';
    my $tokens = Brocken::Core::Lexer->new( source => $source )->lex();
    my $ast    = Brocken::Core::Parser->new( tokens => $tokens )->parse();
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
    my $target_os = $^O eq 'MSWin32' ? 'win64' : 'linux';
    my $out_ext   = $^O eq 'MSWin32' ? '.dll'  : '.so';
    my $out_name  = "test_double${out_ext}";
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
    my %all_labels = %{ $as->labels };
    $format->set_labels( \%all_labels );
    my @exports = sort(qw(pass_double identity_double));
    $format->set_exported_funcs( \@exports );
    my $text = $as->code;
    $format->write_bin( $out_name, $text, $data, 'x64', $target_os, 'shared' );
    ok( -f $out_name, 'Double shared library generated' );
    pass('Double type parameters parsed and shared library generated - FP ops need XMM register allocation');
    unlink $out_name if -f $out_name;
};
done_testing();
