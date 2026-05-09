use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class', 'uninitialized';
use lib 'lib';
$|++;
use JSON         ();
use Time::HiRes  qw(time);
use Getopt::Long qw(GetOptions);
use List::Util   qw(shuffle);

# --- Configuration ---
my $ITERATIONS = 1000;
my $VERBOSE    = 0;
my $TARGET     = 'all';
my $RESUME     = '';
my $TIMEOUT    = 5;
my $SEED_DIR   = 'fuzz/cases';
my $MEMLIMIT   = 0;
Getopt::Long::config('bundling');
GetOptions(
    'iterations=i' => \$ITERATIONS,
    'verbose'      => \$VERBOSE,
    'target=s'     => \$TARGET,
    'resume=s'     => \$RESUME,
    'timeout=i'    => \$TIMEOUT,
    'memlimit=i'   => \$MEMLIMIT,
    ) or
    die "Usage: $0 [--iterations=N] [--verbose] [--target=T] [--resume=F] [--timeout=N] [--memlimit=M]\n" .
    "  Targets: all, codegen, emitter, format, lexer, parser, source, lowering, dwarf, seh\n";
say "[fuzz] Brocken Fuzzing Harness";
say "[fuzz] Target: $TARGET  Iterations: $ITERATIONS  Timeout: ${TIMEOUT}s" . ( $MEMLIMIT ? "  MemLimit: ${MEMLIMIT}MB" : '' );

# --- Statistics ---
my %stats = ( iterations => 0, crashes => 0, panics => 0, timeouts => 0, ooms => 0, ok => 0, lexer => 0, parser => 0, compiler => 0, );
my @crash_log;
my %coverage;

# --- Load seeds ---
my @seeds = load_seeds($SEED_DIR);
say "[fuzz] Loaded " . scalar(@seeds) . " seed case(s) from $SEED_DIR" if $VERBOSE;

# --- Resume from previous crash log ---
if ( $RESUME && -f $RESUME ) {
    open my $fh, '<', $RESUME or die "Cannot read $RESUME: $!";
    while (<$fh>) { chomp; push @crash_log, $_; }
    close $fh;
    say "[fuzz] Loaded " . scalar(@crash_log) . " previous crash(es) from $RESUME";
}

# --- RNG ---
my $rng = bless { seed => 42, count => 0 }, 'RNG';

# --- Source fragment pool for source-level fuzzing ---
my @SOURCE_FRAGMENTS = (

    # Expressions
    '42',       '-1', '0', 'true', 'false', '"hello"', '"😀🔥"', '"line\nbreak"', '$x', '$val', '$result', '$tmp', '$i', '$n', '$s', '$x + 1', '$n * 2',
    '$val - 3', '$i / 2', '$n % 10', '$x == 0', '$n != 0', '$val < 10', '$i > 0', '$n <= 5', '$x >= 0', '$x && $y', '$n || $val', '!$done',
    '$x ? "yes" : "no"', '($x + 1) * 2',

    # Statements
    'my Int $x = 0;', 'my String $s = "";', 'my Bool $b = true;', 'my Any $v = 42;', 'my $x = 10;', 'my $n = 0;', 'my $result = 0;', 'my $tmp = 0;',
    'my $acc = 0;',   'my $done = false;',  '$x = 42;',           '$n = $n + 1;', '$result = $x * 2;', '$tmp = $n;', 'if ($x == 0) { say "zero"; }',
    'if ($n > 0) { $acc = $n; } else { $acc = 0; }', 'unless ($done) { say "not done"; }', 'while ($i < 10) { $i = $i + 1; }',
    'until ($n == 5) { $n = $n + 1; }', 'say $x;', 'say "hello";', 'say $result;', 'print $n;', 'print "test";', 'return $x;', 'return;', 'exit 0;',
    '{ my Int $x = 10; say $x; }',

    # Functions & Fibers
    'sub add(Int $a, Int $b) { return $a + $b; }', 'sub identity(Any $x) { return $x; }', 'sub empty() { return; }',
    'my Any $f = fiber { yield 42; return 99; };',

    # Classes
    'class Foo { field $id; field $name; method get_id() { return $id; } }', 'class Empty { }',

    # Defer
    'defer { say "cleanup"; }',

    # Map
    'map { $_ * 2 } $arr',

    # Arrays
    '[1, 2, 3]', '[]', '[$x, $n, 42]',
);

# --- Invalid / Edge-case inputs for lexer ---
my @EDGE_SOURCES = (
    '',                                                          # Empty
    ' ',                                                         # Whitespace only
    "\t",                                                        # Tab
    "\n",                                                        # Newline only
    ';',                                                         # Bare semicolon
    ';;;;',                                                      # Multiple semicolons
    '# comment',                                                 # Comment only
    '"',                                                         # Unclosed string
    '"\\',                                                       # Unclosed escape
    "\"hello\nworld\"",                                          # String with newline
    '0xDEAD',                                                    # Hex-like (not supported)
    '1_000_000',                                                 # Perl-style numeric separator
    '😀',                                                         # Emoji as identifier
    '42foo',                                                     # Digit+ident
    'my $=42;',                                                  # Bad var
    'my @arr;',                                                  # Array sigil
    'my %hash;',                                                 # Hash sigil
    'sub {}',                                                    # Anonymous sub without name
    'class {}',                                                  # Anonymous class
    '->',                                                        # Lone deref
    '=>',                                                        # Fat comma
    '...',                                                       # Ellipsis
    '`backtick`',                                                # Backticks
    '$',                                                         # Lone sigil
    '@',                                                         # Lone array sigil
    '%',                                                         # Lone hash sigil
    "my \$x = \"\x{00}\";",                                      # Null byte in string
    "\x{FF}\x{FE}",                                              # BOM
    "my \$x = " . ( "A" x 10000 ) . ";",                         # Very long ident
    "say " .      ( "(" x 100 ) . "42" . ( ")" x 100 ) . ";",    # Deep nesting
);

# --- Main fuzz loop ---
my $start_time = time();
ITERATION:
for my $iter ( 1 .. $ITERATIONS ) {
    $stats{iterations}++;
    my $data = generate_fuzz_input($rng);
    my $ok   = eval {
        local $SIG{ALRM}     = sub { die "FUZZ_TIMEOUT\n" };
        local $SIG{__WARN__} = sub { };                        # Suppress expected noise from malformed input
        alarm($TIMEOUT);
        run_fuzz_target( $TARGET, $data );
        alarm(0);
        1;
    };
    alarm(0);
    my $error = $@;
    if ( !$ok ) {
        if ( $error =~ /FUZZ_TIMEOUT/ ) {
            $stats{timeouts}++;
            log_crash( 'TIMEOUT', $data, $error );
        }
        elsif ( $error =~ /Out of memory/i ) {
            $stats{ooms}++;
            log_crash( 'OOM', $data, $error );
        }
        elsif ( $error =~ /panic/i ) {
            $stats{panics}++;
            log_crash( 'PANIC', $data, $error );
        }
        else {
            $stats{crashes}++;
            log_crash( 'CRASH', $data, $error );
        }
        print "!" if $VERBOSE;
    }
    else {
        $stats{ok}++;
        update_coverage($data);
        print "." if $VERBOSE && $iter % 50 == 0;
    }
    if ( $VERBOSE && $iter % 100 == 0 ) {
        my $elapsed = time() - $start_time;
        printf "\n  [%6d/%d] iter/s=%.1f ok=%d crashes=%d panics=%d timeouts=%d ooms=%d cov=%d\n", $iter, $ITERATIONS, $iter / $elapsed, $stats{ok},
            $stats{crashes}, $stats{panics}, $stats{timeouts}, $stats{ooms}, scalar( keys %coverage );
    }
}

# --- Summary ---
my $elapsed = time() - $start_time;
say "\n" . ( '=' x 60 );
say "Fuzzing Complete";
say "  Iterations:  $stats{iterations}";
say "  OK:          $stats{ok}";
say "  Crashes:     $stats{crashes}";
say "  Panics:      $stats{panics}";
say "  Timeouts:    $stats{timeouts}";
say "  OOMs:        $stats{ooms}";
say "  Coverage:    " . scalar( keys %coverage ) . " unique op/paths";
say "  Elapsed:     " . sprintf( '%.1fs',       $elapsed );
say "  Rate:        " . sprintf( '%.1f iter/s', $stats{iterations} / $elapsed );

if (@crash_log) {
    write_crash_log( \@crash_log );
}

# --- Fuzz Input Generation ---
sub generate_fuzz_input {
    my ($rng) = @_;
    my $target = $TARGET;
    if ( $target eq 'all' ) {
        my @targets = qw(codegen emitter format lexer parser source lowering dwarf seh);
        $target = $targets[ int( rand(@targets) ) ];
    }
    if ( $target eq 'lexer' || $target eq 'parser' || $target eq 'source' ) {
        return { type => 'source', target => $target, source => generate_random_source($rng) };
    }
    if ( $target eq 'lowering' ) {
        return { type => 'source', target => $target, source => generate_random_source($rng) };
    }
    if ( $target eq 'format' ) {
        return { type => 'raw', target => $target, bytes => generate_random_bytes($rng) };
    }
    if ( $target eq 'dwarf' ) {
        return { type => 'ir', target => $target, ir => generate_fuzz_ir_for_dwarf($rng) };
    }
    if ( $target eq 'seh' ) {
        return { type => 'ir', target => $target, ir => generate_mutated_ir($rng) };
    }
    return { type => 'ir', target => $target, ir => generate_mutated_ir($rng) };
}

sub generate_random_source {
    my ($rng) = @_;

    # 30% chance: return an edge-case input
    if ( rand() < 0.3 ) {
        return $EDGE_SOURCES[ int( rand(@EDGE_SOURCES) ) ];
    }

    # 70% chance: build random Brocken program
    my @lines;
    my $num_stmts = 1 + int( rand(20) );

    # Sometimes add a sub definition
    if ( rand() < 0.3 ) {
        push @lines, random_sub($rng);
    }

    # Sometimes add a class
    if ( rand() < 0.15 ) {
        push @lines, random_class($rng);
    }
    for ( 1 .. $num_stmts ) {
        push @lines, random_source_line($rng);
    }
    return join( "\n", @lines );
}

sub random_sub {
    my ($rng)      = @_;
    my $name       = random_ident();
    my $num_params = int( rand(4) );
    my @params;
    for ( 1 .. $num_params ) {
        my $type = random_type();
        push @params, "$type \$$name" . ( 100 + int( rand(900) ) );
    }
    my @body;
    for ( 1 .. 1 + int( rand(5) ) ) {
        push @body, random_source_line($rng);
    }
    return "sub $name(" . join( ', ', @params ) . ") {\n    " . join( "\n    ", @body ) . "\n}";
}

sub random_class {
    my ($rng)       = @_;
    my $name        = random_ident();
    my $num_fields  = int( rand(3) );
    my $num_methods = int( rand(2) );
    my @members;
    for ( 1 .. $num_fields ) {
        my $type = random_type();
        push @members, "    field \$$name" . ( 100 + int( rand(900) ) ) . ";";
    }
    for ( 1 .. $num_methods ) {
        my $mname = random_ident();
        my @mbody;
        for ( 1 .. 1 + int( rand(3) ) ) {
            push @mbody, random_source_line($rng);
        }
        push @members, "    method $mname() {\n        " . join( "\n        ", @mbody ) . "\n    }";
    }
    return "class $name {\n" . join( "\n", @members ) . "\n}";
}

sub random_source_line {
    my ($rng) = @_;
    return $SOURCE_FRAGMENTS[ int( rand(@SOURCE_FRAGMENTS) ) ];
}

sub random_ident {
    my @prefix = qw(foo bar baz test helper calc run proc handle obj item tmp val);
    return $prefix[ int( rand(@prefix) ) ] . ( 100 + int( rand(900) ) );
}

sub random_type {
    my @types = qw(Int String Any Bool);
    return $types[ int( rand(@types) ) ];
}

# --- IR Generation & Mutation ---
sub generate_mutated_ir {
    my ($rng) = @_;
    my $seed = $seeds[ int( rand(@seeds) ) ];
    return mutate_ir( $rng, $seed );
}

sub generate_fuzz_ir_for_dwarf {
    my ($rng) = @_;
    my $seed  = $seeds[ int( rand(@seeds) ) ];
    my $ir    = mutate_ir( $rng, $seed );

    # Add source_loc ops to exercise DWARF line table building
    if ( rand() < 0.5 ) {
        my $pos = int( rand( scalar(@$ir) + 1 ) );
        splice @$ir, $pos, 0, { op => 'source_loc', dest => '%_', args => [ 1 + int( rand(100) ), 1 + int( rand(80) ) ] };
    }
    return $ir;
}

sub load_seeds {
    my ($dir) = @_;
    my @seeds;
    if ( -d $dir ) {
        opendir my $dh, $dir or return @seeds;
        for my $file ( sort grep {/\.json$/} readdir($dh) ) {
            open my $fh, '<', "$dir/$file" or next;
            my $json = do { local $/; <$fh> };
            close $fh;
            push @seeds, decode_ir($json);
        }
        closedir $dh;
    }
    push @seeds, default_seeds() unless @seeds;
    return @seeds;
}

sub default_seeds {
    return (
        [ { op => 'jmp', target => 'L_end' }, { op => 'label', name => 'L_end' } ],
        [   { op => 'label',    name => 'L_start' },
            { op => 'constant', dest => '%1', args => [42] },
            { op => 'constant', dest => '%2', args => [10] },
            { op => 'add',      dest => '%3', args => [ '%1', '%2' ] }
        ],
        [   { op => 'constant', dest => '%1', args   => [1] },
            { op => 'cond_br',  reg  => '%1', true_l => 'L_t', false_l => 'L_f' },
            { op => 'label',    name => 'L_t' },
            { op => 'label',    name => 'L_f' }
        ],
        [   { op => 'constant',    dest => '%1', args => [0] },
            { op => 'local_store', args => [ 8, '%1' ] },
            { op => 'local_load',  dest => '%2', args => [8] }
        ],
    );
}

sub mutate_ir {
    my ( $rng, $seed ) = @_;
    my $ir = [];
    for my $inst (@$seed) {
        my $mutated = {%$inst};
        if ( exists $mutated->{args} ) {
            $mutated->{args} = [
                map {
                    rand() < 0.3     ? int( rand(4294967296) ) - 2147483648 :    # wide range
                        rand() < 0.1 ? int( rand(65536) ) : $_
                } @{ $mutated->{args} }
            ];
        }
        if ( exists $mutated->{dest} ) {
            $mutated->{dest} = '%' . int( rand(32) ) if rand() < 0.15;
        }
        if ( exists $mutated->{target} ) {
            $mutated->{target} = 'L_' . int( rand(20) ) if rand() < 0.2;
        }
        if ( exists $mutated->{reg} ) {
            $mutated->{reg} = '%' . int( rand(32) ) if rand() < 0.2;
        }
        push @$ir, $mutated;
    }

    # 30% chance: insert random instructions at random positions
    if ( rand() < 0.3 ) {
        my $pos   = int( rand( scalar(@$ir) + 1 ) );
        my $count = 1 + int( rand(3) );
        my @new_insts;
        for ( 1 .. $count ) {
            push @new_insts, random_instruction($rng);
        }
        splice @$ir, $pos, 0, @new_insts;
    }

    # 20% chance: remove random instructions
    if ( rand() < 0.2 && @$ir > 2 ) {
        my $pos = int( rand( scalar(@$ir) ) );
        splice @$ir, $pos, 1;
    }

    # 15% chance: duplicate a random instruction
    if ( rand() < 0.15 && @$ir > 1 ) {
        my $pos   = int( rand( scalar(@$ir) ) );
        my $clone = { %{ $ir->[$pos] } };
        splice @$ir, $pos, 0, $clone;
    }

    # 10% chance: reorder instructions (swap adjacent)
    if ( rand() < 0.1 && @$ir > 1 ) {
        my $pos = int( rand( scalar(@$ir) - 1 ) );
        @{$ir}[ $pos, $pos + 1 ] = @{$ir}[ $pos + 1, $pos ];
    }
    return $ir;
}
my @OPS = qw(jmp constant mov add sub mul div mod cmp_eq cmp_ne cmp_lt cmp_gt cmp_le cmp_ge
    local_store local_load load_mem_disp store_mem_disp enter_func leave_func
    label cond_br shadow_push shadow_get get_arg call_func load_data_addr
    source_loc intrinsic_print intrinsic_print_char intrinsic_alloc intrinsic_exit
    intrinsic_setup_fault_handler intrinsic_setup_env get_isolate_ctx set_isolate_ctx
    store_iso_disp load_iso_disp load_mem_byte store_mem_byte
    load_func_addr and or shl shr);

sub random_instruction {
    my ($rng) = @_;
    return {
        op     => $OPS[ int( rand(@OPS) ) ],
        dest   => '%' . int( rand(16) ),
        args   => [ int( rand(65536) ), int( rand(65536) ) ],
        target => 'L_' . int( rand(10) ),
        reg    => '%' . int( rand(16) ),
    };
}

# --- Fuzz Targets ---
sub run_fuzz_target {
    my ( $target, $data ) = @_;
    if ( $data->{type} eq 'raw' ) {
        if ( $target eq 'all' || $target eq 'format' ) {
            fuzz_format( $data->{bytes} );
        }
        return;
    }
    if ( $data->{type} eq 'source' ) {
        my $source = $data->{source};
        $stats{lexer}++ if $target eq 'lexer';

        # Lexer phase
        require Brocken::Lexer;
        my $tokens = eval { Brocken::Lexer->new( source => $source )->lex() };
        if ($@) { die "LEXER: $@" }
        $stats{lexer}++ if $target eq 'all';
        if ( $target eq 'parser' || ( $target eq 'all' && $tokens && @$tokens > 0 ) ) {
            $stats{parser}++;
            require Brocken::Parser;
            my $ast = eval { Brocken::Parser->new( tokens => $tokens )->parse() };
            if ($@) { die "PARSER: $@" }

            # Full compilation for source target
            if ( $target eq 'source' || ( $target eq 'all' && rand() < 0.3 ) ) {
                $stats{compiler}++;
                require Brocken;    # defines Brocken::Scope
                require Brocken::Compiler;
                require Brocken::Compiler::DataSegment;
                require Brocken::Compiler::Lowering;
                my $driver   = Brocken::Compiler->new( debug => 0 );
                my $ds       = Brocken::Compiler::DataSegment->new();
                my $lowering = Brocken::Compiler::Lowering->new( data_segment => $ds, driver => $driver );
                eval { $lowering->lower_program($ast) };
                if ($@) { die "LOWERING: $@" }
                require Brocken::Target::X64;
                require Brocken::Target::X64::Emit;
                require Brocken::Codegen;
                my $codegen = Brocken::Codegen->new( arch => 'x64' );
                eval { $codegen->compile( [ $lowering->builder->instructions() ], $driver ) };
                if ($@) { die "CODEGEN: $@" }
            }
        }
        return;
    }

    # IR-level targets
    my $ir = $data->{ir};
    if ( $target eq 'lowering' ) {
        require Brocken;    # defines Brocken::Scope
        require Brocken::Compiler;
        require Brocken::Compiler::DataSegment;
        require Brocken::Compiler::Lowering;
        my $driver   = Brocken::Compiler->new( debug => 0 );
        my $ds       = Brocken::Compiler::DataSegment->new();
        my $lowering = Brocken::Compiler::Lowering->new( data_segment => $ds, driver => $driver );
        eval { $lowering->lower_program($ir) };
        if ($@) { die "LOWERING: $@" }
        return;
    }
    if ( $target eq 'all' || $target eq 'codegen' ) {
        fuzz_codegen($ir);
    }
    if ( $target eq 'all' || $target eq 'emitter' ) {
        fuzz_emitter($ir);
    }
    if ( $target eq 'all' || $target eq 'format' ) {
        fuzz_format( encode_ir($ir) );
    }
    if ( $target eq 'lowering' || ( $target eq 'all' && rand() < 0.25 ) ) {
        fuzz_lowering($ir);
    }
    if ( $target eq 'dwarf' || ( $target eq 'all' && rand() < 0.15 ) ) {
        fuzz_dwarf($ir);
    }
    if ( $target eq 'seh' || ( $target eq 'all' && rand() < 0.15 ) ) {
        fuzz_seh($ir);
    }
}

sub fuzz_codegen {
    my ($ir) = @_;
    require Brocken::Compiler;
    require Brocken::Target::X64;
    require Brocken::Target::X64::Emit;
    require Brocken::Codegen;
    my $driver  = Brocken::Compiler->new( debug => 0 );
    my $codegen = Brocken::Codegen->new( arch => 'x64' );
    $codegen->compile( $ir, $driver );
}

sub fuzz_emitter {
    my ($instructions) = @_;
    require Brocken::Target::X64::Emit;
    my $as = Brocken::Target::X64::Emit->new;
    for my $inst (@$instructions) {
        last if defined( $as->code ) && length( $as->code ) > 65536;
        eval { emit_random_instruction( $as, $inst ) };
    }
}

sub fuzz_format {
    my ($data) = @_;
    require Brocken::Format::PE;
    require Brocken::Format::ELF;

    # PE write with random text/data
    my $pe = Brocken::Format::PE->new;
    $pe->pre_layout( length($data) + 4096, 1024, 'x64', 'win64', 0 );
    $pe->write_bin( 'fuzz_tmp_pe.exe', $data, "\0" x 512, 'x64', 'win64' );

    # ELF write
    my $elf = Brocken::Format::ELF->new;
    $elf->pre_layout( length($data) + 4096, 1024, 'x64', 'linux', 0 );
    $elf->write_bin( 'fuzz_tmp_elf', $data, "\0" x 512, 'x64', 'linux' );
}

sub generate_random_bytes {
    my ($rng) = @_;
    my $len = 1 + int( rand(4096) );
    return pack( 'C*', map { int( rand(256) ) } 1 .. $len );
}

sub fuzz_dwarf {
    my ($ir) = @_;
    require Brocken::Format::DWARF;
    my @sls   = ( { offset => 0, line => 1, col => 1 }, { offset => 64, line => 5, col => 8 }, { offset => 128, line => 10, col => 4 }, );
    my @funcs = (
        { name => 'fuzz_a', start => 0,   end => 96,  ctx_size => 64, params => [], locals => [] },
        { name => 'fuzz_b', start => 256, end => 384, ctx_size => 48, params => [], locals => [] },
    );
    my $text_base = 0x401000;
    my $eh_base   = 0x405000;
    my $dw        = Brocken::Format::DWARF->new(
        source_locs   => \@sls,
        text_base     => $text_base,
        func_ranges   => \@funcs,
        context_size  => 64,
        eh_frame_base => $eh_base,
    );
    my $sections = $dw->build_all;

    for my $k ( keys %$sections ) {
        my $len = length( $sections->{$k} );
        if ( $len > 1048576 ) { die "DWARF section $k too large: ${len}bytes"; }
    }
}

sub fuzz_seh {
    my ($ir) = @_;
    require Brocken::Format::PE;
    my $pe    = Brocken::Format::PE->new;
    my @funcs = (
        { name => 'fuzz_a', start => 0,   end => 96,  ctx_size => 64, params => [], locals => [] },
        { name => 'fuzz_b', start => 256, end => 384, ctx_size => 48, params => [], locals => [] },
    );
    $pe->set_func_ranges( \@funcs );
    my $xdata = $pe->_build_xdata;
    if ( length($xdata) > 65536 ) { die "SEH xdata too large"; }
    my $pdata = $pe->_build_pdata( 0x1000, 0x5000 );
    if ( length($pdata) > 65536 ) { die "SEH pdata too large"; }
}

sub emit_random_instruction {
    my ( $as, $inst ) = @_;
    $as->append_code( pack( 'C*', map { int( rand(256) ) } 1 .. int( rand(32) ) ) );
}

# --- Coverage Tracking ---
sub update_coverage {
    my ($data) = @_;
    if ( $data->{type} eq 'ir' && $data->{ir} ) {
        for my $inst ( @{ $data->{ir} } ) {
            $coverage{ "ir_op:" . ( $inst->{op} // 'undef' ) } = 1;
        }
    }
    if ( $data->{type} eq 'source' ) {
        $coverage{ "source_len:" . length( $data->{source} ) } = 1;
    }
    if ( $data->{type} eq 'raw' ) {
        $coverage{ "raw_len:" . length( $data->{bytes} ) } = 1;
    }
}

# --- Utilities ---
sub decode_ir {
    my ($json) = @_;
    return eval { JSON::decode_json($json) } // [];
}

sub encode_ir {
    my ($ir) = @_;
    return JSON::encode_json($ir);
}

sub log_crash {
    my ( $type, $data, $error ) = @_;
    my $payload;
    if ( $data->{type} eq 'source' ) {
        $payload = $data->{source};
    }
    elsif ( $data->{type} eq 'raw' ) {
        $payload = unpack( 'H*', $data->{bytes} );
    }
    else {
        $payload = encode_ir( $data->{ir} );
    }
    chomp $error;
    $error =~ s/\s+/ /g;
    my $entry = "[$type] " . ( $data->{target} // '?' ) . " | $payload | $error";
    push @crash_log, $entry;
    say "\n  [$type][" . ( $data->{target} // '?' ) . "] $error" if $VERBOSE;
}

sub generate_replay {
    my ($entry) = @_;
    $entry =~ s/^\[.*?\]\s*//;
    my ($target) = $entry =~ s/^(\w+)\s*\|\s*// ? $1 : 'codegen';
    $entry =~ s/\s*\|\s*[^|]*$//;
    if ( $target eq 'lexer' || $target eq 'parser' || $target eq 'source' ) {
        my $source = $entry;
        return <<"REPLAY";
use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';
use lib 'lib';

# Replay script for last fuzz crash ($target)
my \$source = $source;

require Brocken::Lexer;
my \$tokens = eval { Brocken::Lexer->new( source => \$source )->lex() };
if (\$@) { die "Replay crash (lexer): \$@"; }

require Brocken::Parser;
my \$ast = eval { Brocken::Parser->new( tokens => \$tokens )->parse() };
if (\$@) { die "Replay crash (parser): \$@"; }

say "Replay succeeded (no crash)";
REPLAY
    }
    return <<"REPLAY";
use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';
use lib 'lib';

# Replay script for last fuzz crash ($target)
my \$ir = $entry;

require Brocken::Target::X64;
require Brocken::Target::X64::Emit;
require Brocken::Codegen;

my \$driver = Brocken::Compiler->new( debug => 0 );
my \$codegen = Brocken::Codegen->new( arch => 'x64' );
eval { \$codegen->compile(\$ir, \$driver); };
if (\$@) { die "Replay crash: \$@"; }
else { say "Replay succeeded (no crash)"; }
REPLAY
}

sub write_crash_log {
    my ($crash_log) = @_;
    say "\n  Crashes logged to crashes.log";
    open my $fh, '>', 'crashes.log' or warn "Cannot write crashes.log: $!";
    print $fh join( "\n---\n", @$crash_log ) . "\n";
    close $fh;
    open my $rfh, '>', 'replay.pl' or warn "Cannot write replay.pl: $!";
    print $rfh generate_replay( $$crash_log[-1] );
    close $rfh;
    say "  Last crash replay written to replay.pl";
}

# --- Simple RNG ---
package RNG {
    sub rand { my $self = shift; $self->{seed} = ( ( $self->{seed} * 1103515245 + 12345 ) & 0x7FFFFFFF ); return $self->{seed} / 0x7FFFFFFF; }
}
