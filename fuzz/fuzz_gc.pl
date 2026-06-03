use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class', 'uninitialized';
use lib 'lib';
use Brocken;
use File::Temp  qw(tempfile);
use Time::HiRes qw(time);
my $ITERATIONS = shift // 100;
my $TIMEOUT    = 30;
my $VERBOSE    = 0;
say "[GC Fuzzer] Testing GC with allocation patterns";
say "[GC Fuzzer] Iterations: $ITERATIONS  Timeout: ${TIMEOUT}s";
my %stats = ( iterations => 0, ok => 0, crashes => 0, timeouts => 0 );

for my $iter ( 1 .. $ITERATIONS ) {
    $stats{iterations}++;
    my $source = _generate_gc_test();
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
            return 'crash';
        }
        return 'ok';
    };
    alarm(0);
    if ( $@ eq "TIMEOUT\n" ) {
        $stats{timeouts}++;
        print "T" if $VERBOSE;
    }
    elsif ( $result eq 'crash' ) {
        $stats{crashes}++;
        print "!" if $VERBOSE;
    }
    else {
        $stats{ok}++;
        print "." if !$VERBOSE || $iter % 10 != 0;
    }
    if ( $VERBOSE && $iter % 20 == 0 ) {
        say sprintf( "  [%d/%d] ok=%d crash=%d timeout=%d", $iter, $ITERATIONS, $stats{ok}, $stats{crashes}, $stats{timeouts} );
    }
}
say "\n" . ( "=" x 50 );
say "GC Fuzzing Complete";
say "  Iterations: $stats{iterations}";
say "  OK:        $stats{ok}";
say "  Crashes:   $stats{crashes}";
say "  Timeouts:  $stats{timeouts}";
say "  Success:   " . sprintf( "%.1f%%", $stats{ok} / $stats{iterations} * 100 );

sub _generate_gc_test {
    my $source = "";
    if ( rand() < 0.3 ) {
        $source .= "class Node { field Any next; field Int val; }\n";
    }
    my @patterns;
    my $num_vars = int( rand(8) ) + 2;
    for ( 1 .. $num_vars ) {
        my $r = rand();
        if ( $r < 0.4 ) {
            my $size = int( rand(20) ) + 1;
            push @patterns, "Any", "[1, " . join( ", ", map { int( rand(100) ) } 1 .. $size ) . "]";
        }
        elsif ( $r < 0.7 && $source =~ /class Node/ ) {
            push @patterns, "Node", "new Node()";
        }
        else {
            push @patterns, "Int", int( rand(1000) );
        }
    }
    my $loops = int( rand(10000) ) + 500;
    my $decls = "";
    for ( my $i = 0; $i < $num_vars; $i++ ) {
        $decls .= "    my $patterns[$i*2] \$v$i = $patterns[$i*2+1];\n";
        if ( $patterns[ $i * 2 ] eq 'Node' && rand() < 0.5 ) {
            my $target = int( rand($num_vars) );
            $decls .= "    \$v$i.next = \$v$target;\n";
        }
    }
    return <<"BROCKEN";
$source
my Int \$i = 0;
while (\$i < $loops) {
$decls
    \$i = \$i + 1;
}
say "Done: \$i";
exit 0;
BROCKEN
}

sub _compile_source {
    my ($source) = @_;
    my ( $fh, $src_file ) = tempfile( 'gc_fuzz_XXXXXX', SUFFIX => '.bkn', UNLINK => 1 );
    print $fh $source;
    close $fh;
    my $bin_file = $src_file . '_out';
    my $compiler = <<"PERL";
use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';
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
my \$est_text = scalar(\$lowering->builder->instructions) * 32 + 4096;
my \$est_data = length(\$ds->get_raw_data()) + 4096;
\$p->format->pre_layout(\$est_text, \$est_data, \$p->arch, \$p->os, \$p->debug);
my \$codegen = Brocken::Codegen->new(arch => \$p->arch);
\$codegen->compile([\$lowering->builder->instructions()], \$p);
\$p->as->resolve();
\$p->format->write_bin('$bin_file', \$p->as->code, \$ds->get_raw_data(), \$p->arch, \$p->os);
PERL
    my ( $cfh, $cfile ) = tempfile( 'gc_compile_XXXXXX', SUFFIX => '.pl', UNLINK => 1 );
    print $cfh $compiler;
    close $cfh;
    my $output = `perl $cfile 2>&1`;
    return ( -e $bin_file ) ? $bin_file : undef;
}
