use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class', 'uninitialized';
use lib 'lib';
use lib 'fuzz/lib';
$|++;
use Getopt::Long qw(GetOptions);
use Time::HiRes  qw(time);
use Fuzz::Check  qw(check_ir is_well_formed check_lowering check_ir_properties);
my $ITERATIONS = 500;
my $VERBOSE    = 0;
my $TIMEOUT    = 5;
Getopt::Long::config('bundling');
GetOptions( 'iterations=i' => \$ITERATIONS, 'verbose' => \$VERBOSE, 'timeout=i' => \$TIMEOUT, ) or
    die "Usage: $0 [--iterations=N] [--verbose] [--timeout=N]\n";
say "[fuzz-check-ir] IR Well-Formedness Checker";
say "[fuzz-check-ir] Validate IR from seeds, mutations, and random generation";
say "[fuzz-check-ir] Iterations: $ITERATIONS  Timeout: ${TIMEOUT}s";
my %stats = ( iterations => 0, ok => 0, violations => 0, crashes => 0 );
my %violation_types;
my $start_time = time();

# Load IR seeds
my @seeds = _load_seeds('fuzz/cases');
say "[fuzz-check-ir] Loaded " . scalar(@seeds) . " seed(s)" if $VERBOSE;
my @CHECKS = qw(label_refs balanced types reachable stack_height dest_uniq);
for my $iter ( 1 .. $ITERATIONS ) {
    $stats{iterations}++;
    my $result = eval {
        local $SIG{ALRM}     = sub { die "FUZZ_TIMEOUT\n" };
        local $SIG{__WARN__} = sub { };
        alarm($TIMEOUT);
        my $ir     = _generate_ir();
        my $errors = check_ir($ir);
        if ($errors) {
            $stats{violations}++;
            for my $e (@$errors) {
                my $type = ( $e =~ /^L\d+:\s*(\w+)/ ) ? $1 : 'other';
                $violation_types{$type}++;
            }
        }
        my $props = check_ir_properties($ir);
        alarm(0);
        1;
    };
    alarm(0);
    if ( !$result ) {
        $stats{crashes}++;
        print "!" if $VERBOSE;
    }
    else {
        $stats{ok}++;
    }
    if ( $VERBOSE && $iter % 100 == 0 ) {
        my $elapsed = time() - $start_time;
        printf "\n  [%4d/%d] iter/s=%.1f ok=%d violations=%d crash=%d", $iter, $ITERATIONS, $iter / $elapsed, $stats{ok}, $stats{violations},
            $stats{crashes};
    }
}
my $elapsed = time() - $start_time;
say "\n" . ( '=' x 60 );
say "IR Check Fuzzing Complete";
say "  Iterations:   $stats{iterations}";
say "  OK:           $stats{ok}";
say "  Violations:   $stats{violations}";
say "  Crashes:      $stats{crashes}";
say "  Elapsed:      " . sprintf( '%.1fs', $elapsed );

if ( keys %violation_types ) {
    say "\nViolation breakdown:";
    for my $t ( sort keys %violation_types ) {
        printf "  %-20s %d\n", $t, $violation_types{$t};
    }
}

# --- IR Generation ---
sub _load_seeds {
    my ($dir) = @_;
    my @seeds;
    if ( -d $dir ) {
        opendir my $dh, $dir or return @seeds;
        for my $file ( sort grep {/\.json$/} readdir($dh) ) {
            open my $fh, '<', "$dir/$file" or next;
            my $json = do { local $/; <$fh> };
            close $fh;
            my $data = eval { JSON::decode_json($json) } // [];
            push @seeds, $data if @$data > 0;
        }
        closedir $dh;
    }
    return @seeds;
}

sub _generate_ir {
    my $strategy = int( rand(5) );
    if ( $strategy == 0 && @seeds ) {

        # Return unmodified seed (should be well-formed)
        my $seed = $seeds[ int( rand(@seeds) ) ];
        return [
            map {
                {%$_}
            } @$seed
        ];
    }
    if ( $strategy == 1 && @seeds ) {

        # Return seed with a single intentional violation
        my $seed = $seeds[ int( rand(@seeds) ) ];
        my $ir   = [
            map {
                {%$_}
            } @$seed
        ];
        _introduce_violation($ir);
        return $ir;
    }
    if ( $strategy == 2 && @seeds ) {

        # Return seed with random mutations
        my $seed = $seeds[ int( rand(@seeds) ) ];
        return _mutate_ir($seed);
    }

    # Generate purely random IR
    return _random_ir();
}

sub _introduce_violation {
    my ($ir) = @_;
    return if @$ir < 3;
    my @types = qw(bad_label bad_reg bad_type missing_enter extra_leave);
    my $type  = $types[ int( rand(@types) ) ];
    if ( $type eq 'bad_label' ) {

        # Change a jmp target to a non-existent label
        for my $inst (@$ir) {
            if ( $inst->{op} eq 'jmp' ) {
                $inst->{target} = 'L_NONEXISTENT_' . int( rand(100) );
                last;
            }
        }
    }
    elsif ( $type eq 'bad_reg' && @$ir > 2 ) {

        # Introduce a vreg redefinition
        my $pos = int( rand( @$ir - 1 ) ) + 1;
        $ir->[$pos]{dest} = '%1';
    }
    elsif ( $type eq 'bad_type' ) {

        # Give an arithmetic op wrong number of args
        for my $inst (@$ir) {
            if ( $inst->{op} eq 'add' ) {
                $inst->{args} = [1];    # Missing second arg
                last;
            }
        }
    }
    elsif ( $type eq 'missing_enter' ) {

        # Remove an enter_func
        for my $i ( 0 .. $#$ir ) {
            if ( $ir->[$i]{op} eq 'enter_func' ) {
                splice @$ir, $i, 1;
                last;
            }
        }
    }
    elsif ( $type eq 'extra_leave' ) {

        # Duplicate a leave_func
        for my $i ( 0 .. $#$ir ) {
            if ( $ir->[$i]{op} eq 'leave_func' ) {
                splice @$ir, $i, 0, { %{ $ir->[$i] } };
                last;
            }
        }
    }
}

sub _mutate_ir {
    my ($seed) = @_;
    my $ir = [
        map {
            {%$_}
        } @$seed
    ];
    for my $inst (@$ir) {
        if ( rand() < 0.2 && exists $inst->{args} ) {
            $inst->{args} = [ map { rand() < 0.5 ? int( rand(65536) ) : $_ } @{ $inst->{args} } ];
        }
        if ( rand() < 0.1 && exists $inst->{dest} ) {
            $inst->{dest} = '%' . int( rand(20) );
        }
        if ( rand() < 0.1 && $inst->{op} eq 'jmp' ) {
            $inst->{target} = 'L_' . int( rand(15) );
        }
    }
    return $ir;
}

sub _random_ir {
    my @ops = qw(constant add sub mul div mod jmp label cond_br enter_func leave_func
        local_store local_load load_mem_disp store_mem_disp shadow_push shadow_get call_func);
    my @ir;
    push @ir, { op => 'label',      name => 'L_start' };
    push @ir, { op => 'enter_func', args => [] };
    for ( 1 .. 1 + int( rand(10) ) ) {
        my $op   = $ops[ int( rand(@ops) ) ];
        my $inst = { op => $op };
        if ( $op eq 'constant' ) {
            $inst->{dest} = '%' . ( 1 + int( rand(8) ) );
            $inst->{args} = [ int( rand(1000) ) ];
        }
        elsif ( $op eq 'label' ) {
            $inst->{name} = 'L_' . int( rand(10) );
        }
        elsif ( $op eq 'jmp' ) {
            $inst->{target} = 'L_' . int( rand(10) );
        }
        elsif ( $op eq 'cond_br' ) {
            $inst->{reg}     = '%' . int( rand(8) );
            $inst->{true_l}  = 'L_' . int( rand(10) );
            $inst->{false_l} = 'L_' . int( rand(10) );
        }
        else {
            $inst->{dest} = '%' . ( 1 + int( rand(8) ) ) if $op !~ /^(enter_func|leave_func|shadow_push|store|jmp)$/;
            $inst->{args} = [ int( rand(100) ), int( rand(100) ) ];
        }
        push @ir, $inst;
    }
    push @ir, { op => 'leave_func', args => [0] };
    return \@ir;
}

# --- JSON loader ---
use JSON::PP ();
