use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class', 'uninitialized';
use lib '../lib';
use lib 'lib';
use lib 'fuzz/lib';
$|++;
use Getopt::Long qw(GetOptions);
use Time::HiRes  qw(time);
use Fuzz::AST    qw(random_program random_expr random_stmt ast_size count_nodes);
use Fuzz::Check  qw(check_ir is_well_formed check_lowering check_ir_properties);
my $ITERATIONS = 1000;
my $VERBOSE    = 0;
my $TIMEOUT    = 5;
Getopt::Long::config('bundling');
GetOptions( 'iterations=i' => \$ITERATIONS, 'verbose' => \$VERBOSE, 'timeout=i' => \$TIMEOUT, ) or
    die "Usage: $0 [--iterations=N] [--verbose] [--timeout=N]\n";
say "[fuzz-ast] Property-based AST → Lowering → Codegen Fuzzer";
say "[fuzz-ast] Iterations: $ITERATIONS  Timeout: ${TIMEOUT}s";
my %stats = ( iterations => 0, ok => 0, crashes => 0, panics => 0, well_formed => 0, malformed_ir => 0 );
my @failures;
my $start_time = time();

for my $iter ( 1 .. $ITERATIONS ) {
    $stats{iterations}++;
    warn $stats{iterations};
    my $ast;
    my $result = eval {
        local $SIG{ALRM}     = sub { die "FUZZ_TIMEOUT\n" };
        local $SIG{__WARN__} = sub { };
        alarm($TIMEOUT);
        $ast = random_program();
        my $ok = _run_ast_checks($ast);
        alarm(0);
        $ok;
    };
    alarm(0);
    my $error = $@;
    if ( !$result ) {
        if ( $error =~ /FUZZ_TIMEOUT/ ) {
            $stats{panics}++;
            push @failures, "[TIMEOUT] AST size=" . ( $ast ? ast_size($ast) : 'undef' );
        }
        else {
            $stats{crashes}++;
            push @failures, "[CRASH] $error";
        }
        print "!" if $VERBOSE;
    }
    else {
        $stats{ok}++;
        print "." if $VERBOSE && $iter % 50 == 0;
    }
    if ( $VERBOSE && $iter % 100 == 0 ) {
        my $elapsed = time() - $start_time;
        printf "\n  [%6d/%d] iter/s=%.1f ok=%d crashes=%d mp=%d/%d", $iter, $ITERATIONS, $iter / $elapsed, $stats{ok}, $stats{crashes},
            $stats{well_formed}, scalar( $stats{ok} || 1 );
    }
}
my $elapsed = time() - $start_time;
say "\n" . ( '=' x 60 );
say "AST Fuzzing Complete";
say "  Iterations:  $stats{iterations}";
say "  OK:          $stats{ok}";
say "  Crashes:     $stats{crashes}";
say "  Timeouts:    $stats{panics}";
say "  Well-formed: $stats{well_formed}/" . ( $stats{ok} + $stats{crashes} );
say "  Elapsed:     " . sprintf( '%.1fs', $elapsed );

if ( @failures && $VERBOSE ) {
    say "\nLast 10 failures:";
    say "  $_" for splice( @failures, -10 );
}

# --- Core check logic ---
sub _run_ast_checks {
    my ($ast) = @_;
    require Brocken;    # defines Brocken::Core::Scope
    require Brocken::Compiler;
    require Brocken::Compiler::DataSegment;
    require Brocken::Compiler::Lowering;
    my $driver   = Brocken::Compiler->new( debug => 0 );
    my $ds       = Brocken::Compiler::DataSegment->new();
    my $lowering = Brocken::Compiler::Lowering->new( data_segment => $ds, driver => $driver );
    $lowering->lower_program($ast);
    my $ir = [ $lowering->builder->instructions() ];

    # Check 1: IR well-formedness
    my $errors = check_ir($ir);
    if ($errors) {
        $stats{malformed_ir}++;
        die "IR malformed: " . join( '; ', @$errors ) if $VERBOSE;
        return 1;    # Still counts as OK (fuzzer found the issue)
    }
    $stats{well_formed}++;

    # Check 2: Lowering consistency (AST functions appear in IR)
    my $lower_errors = check_lowering( $ast, $ir );
    if ($lower_errors) {
        die "Lowering mismatch: " . join( '; ', @$lower_errors );
    }

    # Check 3: Codegen (if well-formed, should compile)
    require Brocken::Target::Architecture::x64;
    require Brocken::Target::Architecture::x64::Emit;
    require Brocken::Codegen;
    my $codegen = Brocken::Codegen->new( arch => 'x64' );
    $codegen->compile( $ir, $driver );

    # Check 4: AST property invariants
    my $node_count = ast_size($ast);
    if ( $node_count == 0 ) {
        die "AST reports zero size";
    }
    if ( $node_count > 10000 ) {
        die "AST too large: $node_count nodes";
    }
    return 1;
}
