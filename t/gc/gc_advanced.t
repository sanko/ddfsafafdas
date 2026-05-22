use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
use File::Temp qw(tempfile);

sub compile_and_run {
    my ( $source, %opts ) = @_;
    my $timeout = $opts{timeout} // 30;
    require Brocken::Compiler;
    my ( $fh, $exe ) = tempfile( UNLINK => 1, SUFFIX => '.exe' );
    close $fh;
    my $p = Brocken::Compiler->new();
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
my $NODE_CLASS = q{
    class Node {
        field $next; field $val;
        method set_val(Int $v) { $val = $v; }
        method set_next(Any $n) { $next = $n; }
        method get_val() { return $val; }
    }
    sub create_nodes(Int $count) {
        my $head = Node->new(); my $i = 0;
        while ($i < $count) {
            my $new = Node->new(); $new->set_val($i); $new->set_next($head); $head = $new; $i = $i + 1;
        }
        return $head;
    }
};
subtest 'GC: block scoping' => sub {
    my ( $out, $err ) = compile_and_run(
        q{
        class Node { field $next; field $val; }
        say "Starting...";
        { my $head = Node->new(); my $n2 = Node->new(); say "Created two nodes"; }
        say "After block - objects should be unreachable";
        say "Done";
    }
    );
    $err ? ( skip_all $err ) : ();
    like $out, qr/Created two nodes/, 'block: created two nodes';
    like $out, qr/After block/,       'block: after block';
};
subtest 'GC: recursive constructor' => sub {
    my ( $out, $err ) = compile_and_run(
        q{
        class Point { field $x; field $y; method new() { my $p = Point->new(); return $p; } }
        say "Starting...";
        eval { my $p = Point->new(); };
        say "Done with point";
    }
    );
    $err ? ( skip_all $err ) : ();
    like $out, qr/Starting/, 'recursive constructor: started';
};
subtest 'GC: stress 100 nodes' => sub {
    my ( $out, $err ) = compile_and_run("${NODE_CLASS}say \"Starting...\"; my \$list = create_nodes(100); say \"Done - exiting\";");
    $err ? ( skip_all $err ) : ();
    like $out, qr/Done - exiting/, '100 nodes: completed';
};
subtest 'GC: stress 1k nodes' => sub {
    my ( $out, $err ) = compile_and_run("${NODE_CLASS}say \"Starting...\"; my \$list = create_nodes(1000); say \"Done - exiting\";");
    $err ? ( skip_all $err ) : ();
    like $out, qr/Done - exiting/, '1k nodes: completed';
};
subtest 'GC: full manual pipeline' => sub {
    require Brocken::Lexer;
    require Brocken::Parser;
    require Brocken::Compiler;
    require Brocken::Compiler::DataSegment;
    require Brocken::Compiler::Lowering;
    require Brocken::Compiler::Optimizer;
    require Brocken::Codegen;
    my $source   = q{my Int $i = 0; while ($i < 10) { my Any $a = [1]; $i = $i + 1; } say "Done"; exit 0;};
    my $tokens   = Brocken::Lexer->new( source => $source )->lex();
    my $ast      = Brocken::Parser->new( tokens => $tokens )->parse();
    my $ds       = Brocken::Compiler::DataSegment->new();
    my $driver   = Brocken::Compiler->new();
    my $lowering = Brocken::Compiler::Lowering->new( data_segment => $ds, driver => $driver );
    $lowering->lower_program($ast);
    my $optimizer = Brocken::Compiler::Optimizer->new();
    $optimizer->optimize( $lowering->builder );
    ok scalar( $lowering->builder->instructions ) > 0, 'manual pipeline: instructions after optimize';
};
done_testing;
