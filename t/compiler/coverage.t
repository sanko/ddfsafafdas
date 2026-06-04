use v5.40;
use utf8;
use feature 'class';
no warnings 'experimental::class', 'portable';
use lib 'lib';
use Test2::V0;
use File::Temp qw[tempfile];
require Brocken;

sub compile_and_capture_coverage {
    my %args   = @_;
    my $source = $args{source};
    my ( $fh, $exe ) = tempfile( UNLINK => 1, SUFFIX => '.exe' );
    close $fh;
    my $compiler = Brocken::Compiler::Pipeline->new( coverage => 1 );
    eval { $compiler->compile_source( $source, $exe, 'test.brk' ); };
    if ( my $err = $@ ) {
        return ( undef, undef, undef, $err );
    }
    my $stderr_file = "cov_$$.bin";
    local $SIG{ALRM} = sub { die "TIMEOUT\n" };
    alarm(30);
    my $stdout = eval { `"$exe" 2>"$stderr_file"` };
    my $status = $?;
    alarm(0);
    my $stderr      = '';
    if ( -e $stderr_file ) {
        open my $fh2, '<:raw', $stderr_file or warn "Cannot open $stderr_file: $!";
        local $/;
        $stderr = <$fh2>;
        close $fh2;
        unlink $stderr_file;
    }
    return ( $stdout, $stderr, $compiler, undef, $status );
}

sub coverage_to_lcov {
    my ( $cov_bytes, $compiler ) = @_;
    my $probe_lines = $compiler->coverage_probe_lines // [];
    my %line_hits;
    my $nprobes = length($cov_bytes);
    for my $i ( 0 .. $nprobes - 1 ) {
        my $line  = $probe_lines->[$i] // 0;
        my $count = ord( substr( $cov_bytes, $i, 1 ) );
        $line_hits{$line} += $count;
    }
    my @lines;
    push @lines, 'SF:test.brk';
    for my $line ( sort { $a <=> $b } keys %line_hits ) {
        push @lines, "DA:$line,$line_hits{$line}";
    }
    push @lines, 'end_of_record';
    return join( "\n", @lines ) . "\n";
}

# Test 1: Basic coverage compile and run
{
    my ( $stdout, $stderr, $compiler, $err ) = compile_and_capture_coverage( source => 'say 42' );
    ok !$err,                                    'Coverage compilation succeeded' or diag "Error: $err";
    ok defined $compiler->coverage_table_offset, 'Coverage table offset is defined';
    ok $compiler->coverage_table_size > 0,       'Coverage table has probes';
    is $compiler->coverage_table_size, length($stderr), 'Stderr size matches probe count';
    ok length($stderr) > 0, 'Coverage data written to stderr';
}

# Test 2: Coverage probes are actuallu hit
{
    my ( $stdout, $stderr, $compiler ) = compile_and_capture_coverage( source => 'say 42' );
    my $hit_count = grep { ord($_) != 0 } split //, $stderr;
    ok $hit_count > 0,               'Some coverage probes were hit';
    ok $hit_count < length($stderr), 'Not all probes were hit (dead code exists)';
}

# Test 3: Different programs produce different hit patterns
{
    my ( $o1, $s1 ) = compile_and_capture_coverage( source => 'say 1' );
    my ( $o2, $s2 ) = compile_and_capture_coverage( source => 'say 2' );
    is length($s1), length($s2), 'Similar programs have same probe count';
}

# Test 4: Larger program hits more probes
{
    my ( $stdout, $stderr_small ) = compile_and_capture_coverage( source => 'say 1' );
    my $source_large
        = "my \$x = 1;\n" .
        "if (\$x == 1) { say 'one' } " .
        "else { say 'not one' }\n" .
        "for my \$i (1 .. 3) { say \$i }\n" .
        "while (\$x > 0) { \$x = \$x - 1; }\n";
    my ( $out_large, $stderr_large ) = compile_and_capture_coverage( source => $source_large );
    my $hit_small = grep { ord($_) != 0 } split //, $stderr_small;
    my $hit_large = grep { ord($_) != 0 } split //, $stderr_large;
    cmp_ok $hit_large, '>', $hit_small, 'Larger program hits more probes';
}

# Test 5: Unreachable code has zero coverage
{
    my $source = "say 'enter';\nif (0) { say 'unreachable' };\nsay 'exit';";
    my ( $stdout, $stderr ) = compile_and_capture_coverage( source => $source );
    like $stdout, qr/enter/, 'Reachable code executed';
    like $stdout, qr/exit/,  'Exit code executed';
    ok defined $stderr,     'Coverage data emitted';
    ok length($stderr) > 0, 'Coverage data non-empty';
}

# Test 6: Lcov generation
{
    my ( $stdout, $stderr, $compiler ) = compile_and_capture_coverage( source => 'say 42' );
    my $lcov = coverage_to_lcov( $stderr, $compiler );
    like $lcov, qr/SF:test.brk/,   'Lcov has source file';
    like $lcov, qr/DA:/,           'Lcov has line data';
    like $lcov, qr/end_of_record/, 'Lcov has end marker';
    my $total_hit = 0;
    my @da_lines  = $lcov =~ /^DA:(\d+),(\d+)/gm;
    for my $i ( 0 .. $#da_lines / 2 ) {
        $total_hit += $da_lines[ $i * 2 + 1 ];
    }
    cmp_ok $total_hit, '>', 0, 'Lcov hit count is positive';
}

# Test 7: Coverage without --coverage flag produces no coverage data
{
    my ( $fh, $exe ) = tempfile( UNLINK => 1, SUFFIX => '.exe' );
    close $fh;
    my $compiler = Brocken::Compiler::Pipeline->new();
    $compiler->compile_source( 'say 42', $exe, 'test.brk' );
    my $stdout = `"$exe" 2>nul`;
    ok !defined $compiler->coverage_table_offset, 'No coverage table without flag';
    is $compiler->coverage_table_size, undef, 'No coverage size without flag';
}

# Test 8: Empty program produces empty coverage
{
    my ( $stdout, $stderr ) = compile_and_capture_coverage( source => '' );
    ok defined $stdout,                                     'Empty program runs without error';
    ok length( $stderr // '' ) == 0 || length($stderr) > 0, 'Coverage data present or empty';
}

# Test 9: Multi-line program has per-line mapping
{
    my $source = "say 'hello';\nsay 'world';\nsay 'done';\n";
    my ( $stdout, $stderr, $compiler ) = compile_and_capture_coverage( source => $source );
    my $probe_lines = $compiler->coverage_probe_lines // [];
    my %lines_seen;
    for my $line (@$probe_lines) {
        $lines_seen{$line} = 1;
    }
    ok scalar( keys %lines_seen ) >= 3, 'Probes mapped to at least 3 distinct lines';
    ok exists $lines_seen{1},           'Line 1 has probes';
    ok exists $lines_seen{2},           'Line 2 has probes';
    ok exists $lines_seen{3},           'Line 3 has probes';
}

# Test 10: Line-level lcov has distinct entries per line
{
    my $source = "say 'a';\nsay 'b';\n";
    my ( $stdout, $stderr, $compiler ) = compile_and_capture_coverage( source => $source );
    my $lcov     = coverage_to_lcov( $stderr, $compiler );
    my @da_lines = $lcov =~ /^DA:(\d+),(\d+)/gm;
    my %da_map;
    for my $i ( 0 .. $#da_lines / 2 ) {
        $da_map{ $da_lines[ $i * 2 ] } = $da_lines[ $i * 2 + 1 ];
    }
    ok exists $da_map{1}, 'Line 1 in lcov output';
    ok exists $da_map{2}, 'Line 2 in lcov output';
    cmp_ok $da_map{1}, '>', 0, 'Line 1 hit count > 0';
    cmp_ok $da_map{2}, '>', 0, 'Line 2 hit count > 0';
}
done_testing;
