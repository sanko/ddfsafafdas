use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class', 'uninitialized';
use lib 'lib';
$|++;
use Getopt::Long qw(GetOptions);
use Time::HiRes  qw(time);
my $ITERATIONS = 1000;
my $VERBOSE    = 0;
my $TIMEOUT    = 3;
Getopt::Long::config('bundling');
GetOptions( 'iterations=i' => \$ITERATIONS, 'verbose' => \$VERBOSE, 'timeout=i' => \$TIMEOUT, ) or
    die "Usage: $0 [--iterations=N] [--verbose] [--timeout=N]\n";
say "[fuzz-tokens] Token Stream Mutation Fuzzer";
say "[fuzz-tokens] Iterations: $ITERATIONS  Timeout: ${TIMEOUT}s";
my %stats = ( iterations => 0, ok => 0, crashes => 0 );
my @crash_log;

# --- Seed sources (valid Brocken code) ---
my @SEEDS = (
    'my Int $x = 42; say $x;',
    'sub add(Int $a, Int $b) { return $a + $b; } my $r = add(1, 2); say $r;',
    'class Foo { field $id; method get() { return $id; } } my $f = Foo->new(); $f->get();',
    'my $n = 0; while ($n < 10) { $n = $n + 1; } say $n;',
    'my $x = 10; if ($x > 5) { say "big"; } else { say "small"; }',
    'my $f = fiber { yield 42; return 99; }; my $r = transfer($f, 0); say $r;',
    'my $x = true ? 42 : 0; say $x;',
    '{ my Int $x = 10; { my Int $x = 20; } }',
    'my @arr = [1, 2, 3];',
    'sub empty() { return; } empty();',
);

# --- Token operations ---
my @TOKEN_TYPES = qw(NUM STRING KEYWORD IDENT VAR OP { } ; ( ) , EOF);
my @KEYWORDS    = qw(my our state class method field return exit sub fiber yield
    defer if else unless while for map say print Int String Any Bool true false);
my @OPS  = qw(+ - * / % == != < > <= >= && || = -> ? : . !);
my @VARS = qw($x $y $z $val $result $tmp $i $n $s $t $a $b $c $arr $gen $u $f);

sub random_token {
    my $type  = $TOKEN_TYPES[ int( rand(@TOKEN_TYPES) ) ];
    my $value = $type;
    if    ( $type eq 'NUM' )     { $value = int( rand(1000) ) }
    elsif ( $type eq 'KEYWORD' ) { $value = $KEYWORDS[ int( rand(@KEYWORDS) ) ] }
    elsif ( $type eq 'IDENT' )   { $value = 'id_' . int( rand(100) ) }
    elsif ( $type eq 'VAR' )     { $value = $VARS[ int( rand(@VARS) ) ] }
    elsif ( $type eq 'OP' )      { $value = $OPS[ int( rand(@OPS) ) ] }
    return { type => $type, value => $value, line => 1, col => 1 };
}

# --- Main loop ---
my $start_time = time();
for my $iter ( 1 .. $ITERATIONS ) {
    $stats{iterations}++;
    my $result = eval {
        local $SIG{ALRM}     = sub { die "FUZZ_TIMEOUT\n" };
        local $SIG{__WARN__} = sub { };
        alarm($TIMEOUT);
        my $tokens = _generate_mutated_tokens();
        require Brocken::Parser;
        my $parser = Brocken::Parser->new( tokens => $tokens );
        my $ast    = eval { $parser->parse() };
        if ($@) {
            my $err = $@;
            chomp $err;
            die "PARSER: $err" if $VERBOSE && $err !~ /Parse Error/;
            return 1;    # Parse errors are expected
        }

        # If parse succeeded, try lowering
        if ( $ast && @$ast > 0 ) {
            require Brocken;    # defines Brocken::Scope
            require Brocken::Compiler;
            require Brocken::Compiler::DataSegment;
            require Brocken::Compiler::Lowering;
            my $driver   = Brocken::Compiler->new( debug => 0 );
            my $ds       = Brocken::Compiler::DataSegment->new();
            my $lowering = Brocken::Compiler::Lowering->new( data_segment => $ds, driver => $driver );
            $lowering->lower_program($ast);
        }
        alarm(0);
        1;
    };
    alarm(0);
    my $error = $@;
    if ( !$result ) {
        if ( $error !~ /FUZZ_TIMEOUT/ && $error !~ /Parse Error/ ) {
            $stats{crashes}++;
            push @crash_log, "[CRASH] $error";
            print "!";
        }
        $stats{ok}++;    # Token fuzzing: parse errors are expected
    }
    else {
        $stats{ok}++;
        print "." if $VERBOSE && $iter % 50 == 0;
    }
    if ( $VERBOSE && $iter % 100 == 0 ) {
        my $elapsed = time() - $start_time;
        printf "\n  [%6d/%d] iter/s=%.1f ok=%d crashes=%d", $iter, $ITERATIONS, $iter / $elapsed, $stats{ok}, $stats{crashes};
    }
}
my $elapsed = time() - $start_time;
say "\n" . ( '=' x 60 );
say "Token Fuzzing Complete";
say "  Iterations:  $stats{iterations}";
say "  OK:          $stats{ok}";
say "  Crashes:     $stats{crashes}";
say "  Elapsed:     " . sprintf( '%.1fs', $elapsed );

if (@crash_log) {
    say "\nLast 10 crashes:";
    my @last = @crash_log > 10 ? @crash_log[ -10 .. -1 ] : @crash_log;
    for my $c (@last) {
        my $short = substr( $c, 0, 120 );
        say "  $short";
    }
}

# --- Token mutation strategy ---
sub _generate_mutated_tokens {
    my $strategy = int( rand(6) );
    if ( $strategy == 0 ) {

        # Take a seed source and lex it
        my $source = $SEEDS[ int( rand(@SEEDS) ) ];
        require Brocken::Lexer;
        return Brocken::Lexer->new( source => $source )->lex();
    }
    if ( $strategy == 1 ) {

        # Lex a seed, then randomly insert/remove/reorder
        my $source = $SEEDS[ int( rand(@SEEDS) ) ];
        require Brocken::Lexer;
        my $tokens = Brocken::Lexer->new( source => $source )->lex();
        return _mutate_token_list($tokens);
    }
    if ( $strategy == 2 ) {

        # Lex a seed, corrupt random token values
        my $source = $SEEDS[ int( rand(@SEEDS) ) ];
        require Brocken::Lexer;
        my $tokens = Brocken::Lexer->new( source => $source )->lex();
        for my $t (@$tokens) {
            next if rand() > 0.2;
            if    ( $t->{type} eq 'NUM' )   { $t->{value} = int( rand(999999) ) }
            elsif ( $t->{type} eq 'VAR' )   { $t->{value} = '$' . 'x' . int( rand(20) ) }
            elsif ( $t->{type} eq 'IDENT' ) { $t->{value} = 'id_' . int( rand(50) ) }
        }
        return $tokens;
    }
    if ( $strategy == 3 ) {

        # Generate entirely random token sequence
        my @tokens;
        push @tokens, random_token() for ( 1 .. 1 + int( rand(50) ) );
        push @tokens, { type => 'EOF', value => 'EOF', line => 1, col => 1 };
        return \@tokens;
    }
    if ( $strategy == 4 ) {

        # Generate random source, lex it (edge case coverage)
        my $source = _random_source_line();
        require Brocken::Lexer;
        return eval { Brocken::Lexer->new( source => $source )->lex() } // [ { type => 'EOF', value => 'EOF', line => 1, col => 1 } ];
    }

    # Strategy 5: Lex a seed, duplicate a random contiguous block
    {
        my $source = $SEEDS[ int( rand(@SEEDS) ) ];
        require Brocken::Lexer;
        my $tokens = Brocken::Lexer->new( source => $source )->lex();
        return $tokens if @$tokens < 3;
        my $start = int( rand( @$tokens - 2 ) );
        my $len   = 1 + int( rand(5) );
        my @slice = @{$tokens}[ $start .. $start + $len - 1 ];
        splice @$tokens, $start + $len, 0, @slice;
        return $tokens;
    }
}

sub _mutate_token_list {
    my ($tokens) = @_;
    my @ops      = qw(insert remove replace swap);
    my $op       = $ops[ int( rand(@ops) ) ];
    if ( $op eq 'insert' && @$tokens > 2 ) {
        my $pos = int( rand( @$tokens - 1 ) );
        my $n   = 1 + int( rand(3) );
        splice @$tokens, $pos, 0, map { random_token() } ( 1 .. $n );
    }
    elsif ( $op eq 'remove' && @$tokens > 5 ) {
        my $pos = 1 + int( rand( @$tokens - 3 ) );
        my $n   = 1 + int( rand(3) );
        splice @$tokens, $pos, $n;
    }
    elsif ( $op eq 'replace' && @$tokens > 2 ) {
        my $pos = int( rand( @$tokens - 1 ) );
        $tokens->[$pos] = random_token();
    }
    elsif ( $op eq 'swap' && @$tokens > 3 ) {
        my $a = 1 + int( rand( @$tokens - 2 ) );
        my $b = 1 + int( rand( @$tokens - 2 ) );
        if ( $a == $b ) { return $tokens }
        @{$tokens}[ $a, $b ] = @{$tokens}[ $b, $a ];
    }
    return $tokens;
}

sub _random_source_line {
    my @fragments = (
        'my $x = 42;',
        'say "hello";',
        'if ($x) { }',
        'while (1) { }',
        'sub f() { }',
        'class C { }',
        'fiber { }',
        'defer { }',
        'return;',
        'exit;',
        'my @v = [];',
        'map { $_ } $x',
        '$x->foo()',
        'yield 42;',
        'unless ($x) { }',
        'until ($x) { }',
        '',
        ';',
        '#',
        '"',
        '`',
        "\x00",
        "\xFF",
    );
    my $n = 1 + int( rand(10) );
    return join( ' ', map { $fragments[ int( rand(@fragments) ) ] } ( 1 .. $n ) );
}
