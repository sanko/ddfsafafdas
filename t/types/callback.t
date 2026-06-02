use strict;
use warnings;
use v5.40;
use lib 'lib', '../../lib';
use Test2::V0;
use Brocken;
use Brocken::Compiler::Pipeline;
use Brocken::Compiler::DataSegment;
use Brocken::Compiler::Lowering;
use Brocken::Compiler::Optimizer;
use Brocken::Codegen;

BEGIN {
    eval { require Affix; Affix->import(); 1 } or plan skip_all => "Affix not available";
}
subtest 'Fun (callback) type parsing' => sub {
    my $source = 'sub test_fun(Fun $f) { return $f; }';
    my $tokens = Brocken::Core::Lexer->new( source => $source )->lex();
    my $ast    = Brocken::Core::Parser->new( tokens => $tokens )->parse();
    ok( $ast, 'Fun type parses correctly' );
};
subtest 'Callback type with signature' => sub {

    # Test that Callback[[Int] => Int] parses correctly - simple version first
    my $source  = 'Callback[[Int] => Int]';
    my $tokensa = Brocken::Core::Lexer->new( source => $source )->lex();

    # Create a dummy sub to use parser
    my $full_source = "sub foo(Callback[[Int] => Int] \$x) { return \$x; }";
    my $tokensb     = Brocken::Core::Lexer->new( source => $full_source )->lex();
    my $ast         = Brocken::Core::Parser->new( tokens => $tokensb )->parse();
    ok( $ast, 'Callback[[Int] => Int] parses correctly' );

    # Test the full pass-through with signature
    my $source2 = <<'BROCKEN';
sub pass_callback(Callback[[Int] => Int] $f) {
    return $f->(3);
}

sub return_null() {
    return 0;
}
BROCKEN
    my $tokens2   = Brocken::Core::Lexer->new( source => $source2 )->lex();
    my $ast2      = Brocken::Core::Parser->new( tokens => $tokens2 )->parse();
    my $target_os = $^O eq 'MSWin32' ? 'win64' : 'linux';
    my $out_ext   = $^O eq 'MSWin32' ? '.dll'  : '.so';
    my $out_name  = "test_fun${out_ext}";
    my $out_file  = ( $^O eq 'MSWin32' ? '' : './' ) . $out_name;

    # 1. Instantiate the pipeline with debug symbols enabled (debug => 4)
    my $driver   = Brocken::Compiler::Pipeline->new( os => $target_os, arch => 'x64', type => 'shared', debug => 4 );
    my $ds       = Brocken::Compiler::DataSegment->new();
    my $lowering = Brocken::Compiler::Lowering->new( driver => $driver, data_segment => $ds );
    $lowering->set_skip_runtime(1);
    $lowering->lower_program($ast2);
    my $optimizer = Brocken::Compiler::Optimizer->new();
    $optimizer->optimize( $lowering->builder );
    my $format = $driver->format;
    my $data   = $ds->raw_data();

    # Calculate text size and pre-layout, passing the debug level as the fifth parameter
    my @insts     = $lowering->builder->instructions;
    my $text_size = scalar(@insts) * 64 + 8192;
    $format->pre_layout( $text_size, length($data), 'x64', $target_os, $driver->debug );
    my $codegen = Brocken::Codegen->new( arch => 'x64' );
    $codegen->compile( \@insts, $driver );
    my $as = $driver->as;
    $as->resolve( $driver->text_rva, $driver->data_rva );
    $format->set_func_ranges( [ $driver->func_ranges ] );
    $format->set_frame_size( $driver->frame_local_size );

    # 2. Construct and register DWARF debug data if debug is enabled
    if ( $driver->debug ) {
        require Brocken::Target::Format::DWARF;
        my $dwarf = Brocken::Target::Format::DWARF->new(
            source_locs    => [ $driver->source_locs ],
            text_base      => $format->image_base + $driver->text_rva,
            func_ranges    => [ $driver->func_ranges ],
            context_size   => $driver->context_size,
            arch           => $driver->arch,
            preserved_regs => $driver->preserved_regs,
            class_info     => { $lowering->class_info },
            source_file    => 'test_fun.brocken'
        );
        my $dwarf_data = $dwarf->build_all();
        $format->set_debug_data($dwarf_data);
        for my $sec ( keys %$dwarf_data ) {
            eval { $format->layout->get($sec)->{size} = length( $dwarf_data->{$sec} ) };
        }
        $format->layout->calculate(0x1000);
    }
    my $all_labels = $as->labels;
    $format->set_labels($all_labels);
    my @exports = sort(qw(pass_callback return_null));
    $format->set_exported_funcs( \@exports );
    my $text = $as->code;
    $format->write_bin( $out_file, $text, $data, 'x64', $target_os, 'shared' );
    ok( -f $out_file, 'Callback shared library generated with debug symbols' );
    affix $out_file, 'pass_callback', [ Callback [ [Int] => Int ] ], Int;
    affix $out_file, 'return_null',   [],                            Int;

    # Callback pointer is passed through - verify we can call with Affix
    # Test that return value from Perl callback works correctly
    my $cb_result = pass_callback( sub { return 42 } );
    is( $cb_result, 42, 'Callback return value correctly returned' );

    # Test with argument - should receive unboxed value
    my $cb_result2 = pass_callback( sub { my $v = shift; return $v * 2; } );

    # If arg is unboxed: 3 * 2 = 6. If arg is boxed: 7 * 2 = 14
    is( $cb_result2, 6, 'Callback receives unboxed argument (3 * 2 = 6)' );
    unlink $out_file if -f $out_file;
};
done_testing();
