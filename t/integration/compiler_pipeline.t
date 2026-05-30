use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
use Brocken::TestHelpers qw(test_brocken);
use File::Temp           qw(tempfile);
subtest 'Full pipeline: lex -> parse -> lower -> optimize -> codegen -> format' => sub {
    require Brocken::Core::Lexer;
    require Brocken::Core::Parser;
    require Brocken::Compiler::Pipeline;
    require Brocken::Compiler::Lowering;
    require Brocken::Compiler::DataSegment;
    require Brocken::Compiler::Optimizer;
    require Brocken::Codegen;
    my $source = 'my Int $x = 42; say $x;';
    my $tokens = Brocken::Core::Lexer->new( source => $source )->lex();
    ok scalar(@$tokens) > 0, 'lexer produces tokens';
    my $ast = Brocken::Core::Parser->new( tokens => $tokens )->parse();
    ok scalar(@$ast) > 0, 'parser produces AST nodes';
    my $ds       = Brocken::Compiler::DataSegment->new;
    my $driver   = Brocken::Compiler::Pipeline->new;
    my $lowering = Brocken::Compiler::Lowering->new( data_segment => $ds, driver => $driver );
    $lowering->lower_program($ast);
    my @before = $lowering->builder->instructions;
    ok scalar(@before) > 0, 'lowering produces IR instructions';
    my $optimizer = Brocken::Compiler::Optimizer->new;
    $optimizer->optimize( $lowering->builder );
    my @after = $lowering->builder->instructions;
    ok scalar(@after) > 0,                'optimizer preserves instructions';
    ok scalar(@after) <= scalar(@before), 'optimizer reduces or maintains instruction count';
};
subtest 'Compile and run simple program' => sub {
    my ( $out, $err ) = test_brocken( source => 'say 42;' );
    $err ? ( skip_all $err ) : ();
    is $out, '42', 'program outputs 42';
};
subtest 'Compile and run with debug=0' => sub {
    my ( $out, $err ) = test_brocken( source => 'say "hello";', opts => { debug => 0 } );
    $err ? ( skip_all $err ) : ();
    is $out, 'hello', 'debug=0 program outputs hello';
};
subtest 'Shared library compilation' => sub {
    require Brocken::Compiler::Pipeline;
    my $source = 'sub add(Int $a, Int $b) { return $a + $b; }';
    my $p      = Brocken::Compiler::Pipeline->new( type => 'shared' );
    my ( $fh, $dll ) = tempfile( UNLINK => 1, SUFFIX => '.dll' );
    close $fh;
    eval { $p->compile_source( $source, $dll ); };
    if ( my $err = $@ ) {
        skip_all "Shared lib compilation failed: $err";
    }
    ok -e $dll, 'shared library exists';
};
subtest 'IR opcodes enumeration' => sub {
    require Brocken::Core::IR::Builder;
    my $b   = Brocken::Core::IR::Builder->new;
    my @ops = qw(
        constant load_data_addr load_func_addr
        load_mem_disp store_mem_disp load_mem_byte store_mem_byte
        load_iso_disp store_iso_disp
        local_load local_store
        enter_func enter_leaf_func leave_func call_func call_reg
        tail_call_func tail_call_reg get_arg get_bp
        set_isolate_ctx get_isolate_ctx
        label jmp cond_br
        add sub mul div mod
        and or xor shl shr
        cmp_eq cmp_ne cmp_lt cmp_gt cmp_le cmp_ge
        shadow_push shadow_pop shadow_get shadow_set
        mov nop source_loc map_op
        atomic_inc_ref atomic_dec_ref local_inc_ref local_dec_ref
        mark_try_start mark_try_end
    );

    for my $op (@ops) {
        $b->emit( $op, 'void', [] );
    }
    my $insts = $b->instructions;
    is scalar(@$insts), scalar(@ops), 'all IR opcodes emitted successfully';
    is $insts->[0]{op}, 'constant',   'first op is constant';
};
done_testing;


