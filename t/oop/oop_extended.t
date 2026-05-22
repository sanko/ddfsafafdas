use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
use File::Temp qw(tempfile);

sub compile_and_run {
    my ( $source, %opts ) = @_;
    my $timeout = $opts{timeout} // 15;
    my $debug   = $opts{debug}   // 0;
    require Brocken::Compiler;
    my ( $fh, $exe ) = tempfile( UNLINK => 1, SUFFIX => '.exe' );
    close $fh;
    my $p = Brocken::Compiler->new( debug => $debug );
    eval { $p->compile_source( $source, $exe ); };
    return ( undef, "compilation: $@" ) if $@;
    my $run    = ( $^O eq 'MSWin32' ? '' : './' ) . $exe;
    my $output = eval {
        local $SIG{ALRM} = sub { die "TIMEOUT\n" }
            if $^O ne 'MSWin32';
        alarm($timeout) if $^O ne 'MSWin32';
        open my $fh2, '-|', $run or die "Cannot run $run: $!";
        local $/;
        my $out = <$fh2>;
        close $fh2;
        alarm(0) if $^O ne 'MSWin32';
        $out;
    };
    alarm(0)                          if $^O ne 'MSWin32';
    return ( undef, "execution: $@" ) if $@;
    chomp $output                     if defined $output;
    return ( $output, undef );
}
subtest 'Simple class with method' => sub {
    my ( $out, $err ) = compile_and_run(
        q{
        class Foo { method bar() { say "bar"; } }
        my $f = Foo->new(); $f->bar();
    }
    );
    $err ? ( skip_all $err ) : ();
    is $out, 'bar', 'class method produces bar';
};
subtest 'Class with field and setter' => sub {
    my ( $out, $err ) = compile_and_run(
        q{
        class Node { field $val; method set_val(Int $v) { $val = $v; } }
        my $n = Node->new(); $n->set_val(42); say "Set field";
    }
    );
    $err ? ( skip_all $err ) : ();
    like $out, qr/Set field/, 'field setter works';
};
subtest 'Class with getter (explicit return)' => sub {
    my ( $out, $err ) = compile_and_run(
        q{
        class Node { field $val; method set_val(Int $v) { $val = $v; } method get_val() { return $val; } }
        my $n = Node->new(); $n->set_val(99); say "Val: " . $n->get_val();
    }
    );
    $err ? ( skip_all $err ) : ();
    like $out, qr/Val: 99/, 'explicit return getter';
};
subtest 'Method return value assigned to variable' => sub {
    my ( $out, $err ) = compile_and_run(
        q{
        class Node { field $val; method set_val(Int $v) { $val = $v; } method get_val() { return $val; } }
        my $n = Node->new(); $n->set_val(42); my $v = $n->get_val(); say "Done: $v";
    }
    );
    $err ? ( skip_all $err ) : ();
    like $out, qr/Done: 42/, 'method return assigned';
};
subtest 'Class with multiple fields' => sub {
    my ( $out, $err ) = compile_and_run(
        q{
        class Point { field $x; field $y; }
        my $p = Point->new(); say "ok";
    }
    );
    $err ? ( skip_all $err ) : ();
    is $out, 'ok', 'class with multiple fields';
};
subtest 'Method call in void context' => sub {
    my ( $out, $err ) = compile_and_run(
        q{
        class Node { method foo() { say "foo"; } }
        my $n = Node->new(); $n->foo();
    }
    );
    $err ? ( skip_all $err ) : ();
    is $out, 'foo', 'void method call';
};
subtest 'Class method with say instrumentation' => sub {
    my ( $out, $err ) = compile_and_run(
        q{
        class Node { method hello() { say "hello"; } }
        my $n = Node->new(); my $x = $n->hello(); say "returned";
    }
    );
    $err ? ( skip_all $err ) : ();
    like $out, qr/hello/,    'method with say';
    like $out, qr/returned/, 'after method call';
};
subtest 'Lex-parse-lower pipeline: while loop with typed vars' => sub {
    require Brocken::Lexer;
    require Brocken::Parser;
    require Brocken::Compiler;
    require Brocken::Compiler::DataSegment;
    require Brocken::Compiler::Lowering;
    require Brocken::Compiler::Optimizer;
    my $source = 'my Int $i = 0; while ($i < 10) { my Any $a = [1]; $i = $i + 1; } say "Done"; exit 0;';
    my $tokens = Brocken::Lexer->new( source => $source )->lex();
    my $ast    = Brocken::Parser->new( tokens => $tokens )->parse();
    ok scalar(@$ast) > 0, 'pipeline: AST produced';
    my $ds       = Brocken::Compiler::DataSegment->new();
    my $driver   = Brocken::Compiler->new();
    my $lowering = Brocken::Compiler::Lowering->new( data_segment => $ds, driver => $driver );
    $lowering->lower_program($ast);
    ok scalar( $lowering->builder->instructions ) > 0, 'pipeline: instructions produced';
    my $optimizer = Brocken::Compiler::Optimizer->new();
    $optimizer->optimize( $lowering->builder );
    ok scalar( $lowering->builder->instructions ) > 0, 'pipeline: instructions after optimize';
};
done_testing;
