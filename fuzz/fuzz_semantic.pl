use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class', 'uninitialized';
use lib 'lib';
use lib 'fuzz/lib';
$|++;
use Getopt::Long      qw(GetOptions);
use Time::HiRes       qw(time);
use File::Temp        qw(tempfile);
use Fuzz::AST         qw(random_program);
use Fuzz::PrettyPrint qw(ast_to_source);
my $ITERATIONS    = 100;
my $VERBOSE       = 0;
my $TIMEOUT       = 10;
my $KEEP_BINARIES = 0;
Getopt::Long::config('bundling');
GetOptions( 'iterations=i' => \$ITERATIONS, 'verbose' => \$VERBOSE, 'timeout=i' => \$TIMEOUT, 'keep!' => \$KEEP_BINARIES, ) or
    die "Usage: $0 [--iterations=N] [--verbose] [--timeout=N] [--keep]\n";
say "[fuzz-semantic] Semantic Integrity Fuzzer";
say "[fuzz-semantic] Compile & run generated programs, verify exit codes";
say "[fuzz-semantic] Iterations: $ITERATIONS  Timeout: ${TIMEOUT}s";
my %stats      = ( iterations => 0, ok => 0, crashes => 0, link_fail => 0, run_fail => 0, exit_mismatch => 0 );
my $start_time = time();

# We use the existing brocken.pl as our compiler — inject the generated source
# and compile it, then run the binary and check the exit code.
for my $iter ( 1 .. $ITERATIONS ) {
    $stats{iterations}++;
    my $result = eval {
        local $SIG{ALRM}     = sub { die "FUZZ_TIMEOUT\n" };
        local $SIG{__WARN__} = sub { };
        alarm($TIMEOUT);
        my $ast    = random_program( 1, 1 );
        my $source = ast_to_source($ast);
        $source = _wrap_program($source);
        my $binary = _compile_source($source);
        if ( !$binary ) {
            $stats{link_fail}++;
            alarm(0);
            return 1;
        }
        my $exit_code = _run_binary($binary);
        if ( !defined $exit_code ) {
            $stats{run_fail}++;
            alarm(0);
            return 1;
        }
        if ( $exit_code != 0 && $exit_code != 42 ) {
            $stats{exit_mismatch}++;
            if ($VERBOSE) {
                warn "  Exit code $exit_code (expected 0 or 42)";
            }
        }
        _cleanup_binary($binary) unless $KEEP_BINARIES;
        alarm(0);
        1;
    };
    alarm(0);
    my $error = $@;
    if ( !$result ) {
        $stats{crashes}++;
        print "!" if $VERBOSE;
    }
    else {
        $stats{ok}++;
        print "." if $VERBOSE && $iter % 10 == 0;
    }
    if ( $VERBOSE && $iter % 20 == 0 ) {
        my $elapsed = time() - $start_time;
        printf "\n  [%3d/%d] iter/s=%.1f ok=%d link=%d run=%d exit=%d crash=%d", $iter, $ITERATIONS, $iter / $elapsed, $stats{ok}, $stats{link_fail},
            $stats{run_fail}, $stats{exit_mismatch}, $stats{crashes};
    }
}
my $elapsed = time() - $start_time;
say "\n" . ( '=' x 60 );
say "Semantic Fuzzing Complete";
say "  Iterations:   $stats{iterations}";
say "  OK:           $stats{ok}";
say "  Link failures: $stats{link_fail}";
say "  Run failures:  $stats{run_fail}";
say "  Exit mismatch: $stats{exit_mismatch}";
say "  Crashes:      $stats{crashes}";
say "  Elapsed:      " . sprintf( '%.1fs', $elapsed );

# --- Helpers ---
sub _wrap_program {
    my ($source) = @_;
    my $exit_stmt = 'exit 0;';
    if ( $source !~ /\bexit\b/ ) {
        $source .= "\n$exit_stmt";
    }
    return $source;
}

sub _compile_source {
    my ($source) = @_;

    # Write the source to a temp file
    my ( $fh, $src_file ) = tempfile( 'brocken_fuzz_XXXXXX', SUFFIX => '.bkn', UNLINK => 1 );
    print $fh $source;
    close $fh;

    # Build the binary name
    my $bin_file = $src_file . '.exe';
    my $ext      = $^O eq 'MSWin32' ? '.exe' : '';

    # Run brocken.pl with this source injected
    # Actually, we need to modify brocken.pl to accept source from file.
    # For now, write a standalone compiler script.
    my $compiler_code = <<"PERL";
use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';
use lib 'lib';
use Brocken;

my \$source = do { open my \$fh, '<', '$src_file'; local \$/; <\$fh> };
my \$p = Brocken::Compiler->new( debug => 0 );
my \$tokens   = Brocken::Lexer->new( source => \$source )->lex();
my \$ast      = Brocken::Parser->new( tokens => \$tokens )->parse();
my \$ds       = Brocken::Compiler::DataSegment->new();
my \$lowering = Brocken::Compiler::Lowering->new( data_segment => \$ds, driver => \$p );
\$lowering->lower_program(\$ast);
my \$optimizer = Brocken::Compiler::Optimizer->new();
\$optimizer->optimize( \$lowering->builder );
my \$est_text = scalar( \$lowering->builder->instructions ) * 32 + 4096;
my \$est_data = length( \$ds->get_raw_data() ) + 4096;
\$p->format->pre_layout( \$est_text, \$est_data, \$p->arch, \$p->os, \$p->debug );
my \$codegen = Brocken::Codegen->new( arch => \$p->arch );
\$codegen->compile( [ \$lowering->builder->instructions() ], \$p );
\$p->as->resolve();
my \$exe = \$p->format->write_bin( '$bin_file', \$p->as->code, \$ds->get_raw_data(), \$p->arch, \$p->os );
PERL
    my ( $cfh, $cfile ) = tempfile( 'brocken_compile_XXXXXX', SUFFIX => '.pl', UNLINK => 1 );
    print $cfh $compiler_code;
    close $cfh;
    my $output = `perl $cfile 2>&1`;
    if ( $? != 0 ) {
        warn "  Compile failed: " . substr( $output, 0, 200 ) if $VERBOSE;
        return undef;
    }
    return ( -e $bin_file ) ? $bin_file : undef;
}

sub _run_binary {
    my ($binary) = @_;
    my $output   = `$binary 2>&1`;
    my $exit     = $? >> 8;
    return $exit;
}

sub _cleanup_binary {
    my ($binary) = @_;
    unlink $binary if -e $binary;
}
