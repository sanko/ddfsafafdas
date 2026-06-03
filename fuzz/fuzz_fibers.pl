use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class', 'uninitialized';
use lib 'lib';
use Brocken;
use File::Temp  qw(tempfile);
use Time::HiRes qw(time);
my $ITERATIONS = shift // 50;
my $TIMEOUT    = 30;
my $VERBOSE    = 1;
say "[Fiber Fuzzer] Testing Fibers, Yield, and Sleep";
say "[Fiber Fuzzer] Iterations: $ITERATIONS  Timeout: ${TIMEOUT}s";
my %stats = ( iterations => 0, ok => 0, crashes => 0, timeouts => 0 );

for my $iter ( 1 .. $ITERATIONS ) {
    $stats{iterations}++;
    my $source = _generate_fiber_test();
    my $result = eval {
        local $SIG{ALRM} = sub { die "TIMEOUT\n" };
        alarm($TIMEOUT);
        my $binary = _compile_source($source);
        if ( !$binary ) {
            alarm(0);
            return 'compile_fail';
        }
        my $output = `$binary 2>&1`;
        my $exit   = $? >> 8;
        unlink $binary if -e $binary;
        alarm(0);
        if ( $output =~ /ERROR|SEGV|Segmentation fault|panic/ ) {
            say "CRASH DETECTED:\n$source\nOutput:\n$output" if $VERBOSE;
            return 'crash';
        }
        return 'ok';
    };
    alarm(0);
    if ( $@ eq "TIMEOUT\n" ) {
        $stats{timeouts}++;
        print "T";
    }
    elsif ( $result eq 'crash' ) {
        $stats{crashes}++;
        print "!";
    }
    elsif ( $result eq 'compile_fail' ) {
        print "C";
    }
    else {
        $stats{ok}++;
        print ".";
    }
    say " ($iter)" if $iter % 50 == 0;
}
say "\n" . ( "=" x 50 );
say "Fiber Fuzzing Complete";
say "  Iterations: $stats{iterations}";
say "  OK:        $stats{ok}";
say "  Crashes:   $stats{crashes}";
say "  Timeouts:  $stats{timeouts}";

sub _generate_fiber_test {
    my $num_fibers = int( rand(5) ) + 1;
    my $logic      = "";
    for my $fid ( 1 .. $num_fibers ) {
        my $sleep       = int( rand(3) );
        my $yields      = int( rand(3) ) + 1;
        my $yield_logic = join( "\n    ", map {"yield 1;"} 1 .. $yields );
        $logic .= <<"FIBER";
my Fiber \$f$fid = sub (Any \$val) {
    sleep $sleep;
    $yield_logic
    return \$fid;
};
FIBER
    }
    my $switches = "";
    for ( 1 .. $num_fibers * 2 ) {
        my $target = int( rand($num_fibers) ) + 1;
        $switches .= "    \$f$target.switch(0);\n";
    }
    return <<"BROCKEN";
$logic
my Int \$i = 0;
while (\$i < 2) {
$switches
    \$i = \$i + 1;
}
say "Done";
exit 0;
BROCKEN
}

sub _compile_source {
    my ($source) = @_;
    my ( $fh, $src_file ) = tempfile( 'fiber_fuzz_XXXXXX', SUFFIX => '.bkn', UNLINK => 1 );
    print $fh $source;
    close $fh;
    my $bin_file = $src_file . '_out';
    my $compiler = <<"PERL";
use v5.40;
use lib 'lib';
use Brocken;

my \$source = do { open my \$fh, '<', '$src_file'; local \$/; <\$fh> };
my \$p = Brocken::Compiler->new(debug => 0);
my \$tokens = Brocken::Core::Lexer->new(source => \$source)->lex();
my \$ast = Brocken::Core::Parser->new(tokens => \$tokens)->parse();
my \$ds = Brocken::Compiler::DataSegment->new();
my \$lowering = Brocken::Compiler::Lowering->new(data_segment => \$ds, driver => \$p);
\$lowering->lower_program(\$ast);
my \$optimizer = Brocken::Compiler::Optimizer->new();
\$optimizer->optimize(\$lowering->builder);
my \$est_text = scalar(\$lowering->builder->instructions) * 32 + 8192;
my \$est_data = length(\$ds->get_raw_data()) + 8192;
\$p->format->pre_layout(\$est_text, \$est_data, \$p->arch, \$p->os, 0);
my \$codegen = Brocken::Codegen->new(arch => \$p->arch);
\$codegen->compile([\$lowering->builder->instructions()], \$p);
\$p->as->resolve();
\$p->format->write_bin('$bin_file', \$p->as->code, \$ds->get_raw_data(), \$p->arch, \$p->os);
PERL
    my ( $cfh, $cfile ) = tempfile( 'fiber_compile_XXXXXX', SUFFIX => '.pl', UNLINK => 1 );
    print $cfh $compiler;
    close $cfh;
    my $output = `perl $cfile 2>&1`;
    return ( -e $bin_file ) ? $bin_file : undef;
}
