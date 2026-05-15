#!/usr/bin/env perl
use v5.40;
use lib '../lib';
use Brocken;

print "Compiling Brocken Shared Library (DLL)...\n";

my $source = <<'BROCKEN';
sub math_add(Int $a, Int $b) {
    say $a;
    say $b;
    return $a + $b;
}

sub get_status_code() {
    return 42;
}
BROCKEN

# 1. Parse & Lower
my $tokens = Brocken::Lexer->new(source => $source)->lex();
my $ast    = Brocken::Parser->new(tokens => $tokens)->parse();

my $driver = Brocken::Compiler->new(
    os    => 'win64',
    arch  => 'x64',
    type  => 'shared',
    debug => 0
);

my $ds = Brocken::Compiler::DataSegment->new();
my $lowering = Brocken::Compiler::Lowering->new(
    driver       => $driver,
    data_segment => $ds
);

# Skip main() runtime loop execution logic for a pure DLL payload
$lowering->set_skip_runtime(1);
$lowering->lower_program($ast);

# 2. Optimize
my $optimizer = Brocken::Compiler::Optimizer->new();
$optimizer->optimize($lowering->builder);

# 3. PRE-LAYOUT (Fixes the circular dependency)
my $format = $driver->format;
my $data   = $ds->get_raw_data();
$format->pre_layout(65536, length($data), 'x64', 'win64');

# 4. Codegen
my $codegen = Brocken::Codegen->new(arch => 'x64');
my @insts = $lowering->builder->instructions;
$codegen->compile(\@insts, $driver);

# 5. Resolve internal machine code jumps
my $as = $driver->as;
$as->resolve();

# 6. Format & Link
$format->set_labels({ $as->labels });

# CRITICAL PE REQUIREMENT: Export names must be alphabetically sorted!
my @exports = sort('math_add', 'get_status_code');
$format->set_exported_funcs(\@exports);

my $text = $as->code;
my $out_dll = "brocken_demo.dll";
$format->write_bin($out_dll, $text, $data, 'x64', 'win64', 'shared');

print "Done! Generated '$out_dll'\n\n";

# ============================================================================
# VERIFICATION
# ============================================================================
print "--- Verifying RVAs ---\n";
my %labels = $as->labels;
for my $name (@exports) {
    my $off = $labels{"M_$name"} // 'MISSING';
    my $rva = sprintf("0x%08X", $format->rva_for('.text') + $off);
    print "  $name -> Text Offset: $off bytes (RVA: $rva)\n";
}
print "\n";

print "--- Checking objdump ---\n";
my $objdump_out = `objdump -p $out_dll 2>&1`;

my @lines = grep { /math_add|get_status_code/ } split /\n/, $objdump_out;

if (@lines) {
    print "Success! Found exports in DLL:\n";
    print "  $_\n" for @lines;
} else {
    print "Output didn't match. Dumping raw .edata section from objdump:\n\n";
    if ($objdump_out =~ /(The Export Tables.*?)(?=\nThe \w+ Tables|\Z)/s) {
        print "$1\n";
    } else {
        print "Could not find 'The Export Tables' in objdump output.\n";
    }
}

use Affix;
affix $out_dll, 'math_add', [Int, Int] => Int;
affix($out_dll, 'get_status_code', [] => Int);

# ============================================================================
# TEST 1: get_status_code()
# ============================================================================
print "--- Testing get_status_code() ---\n";
my $status_raw = get_status_code();
my $status     = $status_raw;

print "Raw return value : $status_raw\n";
print "Untagged value   : $status\n\n";

# ============================================================================
# TEST 2: math_add(5, 7)
# ============================================================================
print "--- Testing math_add(5, 7) ---\n";

# Tag the integers before passing them into the ABI
my $a_raw =  5;
my $b_raw =  7;

# Call the DLL!
my $sum_raw = math_add($a_raw, $b_raw);

# Untag the result
my $sum = $sum_raw;

print "Passed in (raw)  : $a_raw (which is 5), $b_raw (which is 7)\n";
print "Raw return value : $sum_raw\n";
print "Untagged value   : $sum\n";
