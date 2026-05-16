#!/usr/bin/env perl
use v5.40;
use lib '../lib', 'lib';
use Brocken;

print "Compiling Brocken Shared Library (DLL)...\n";

my $source = <<'BROCKEN';
sub math_add(Int $a, Int $b) {
    say "Hi!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!! $a, $b";
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
$lowering->builder->dump_ir("DLL IR");

# 3. PRE-LAYOUT (Fixes the circular dependency)
my $format = $driver->format;
my $data   = $ds->get_raw_data();
say "Data Segment Size: " . length($data) . " bytes";
$format->pre_layout(65536, length($data), 'x64', 'win64');

# 4. Codegen
my $codegen = Brocken::Codegen->new(arch => 'x64');
my @insts = $lowering->builder->instructions;
$codegen->compile(\@insts, $driver);

# 5. Resolve internal machine code jumps
my $as = $driver->as;
$as->resolve($driver->text_rva, $driver->data_rva);

# 6. Format & Link
my %all_labels = $as->labels;
$format->set_labels(\%all_labels);

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

print "--- Internal Labels ---\n";
my %all_labels = $driver->as->labels;
for my $l (sort keys %all_labels) {
    printf "  %-30s -> 0x%04X (RVA: 0x%04X)\n", $l, $all_labels{$l}, $all_labels{$l} + 0x1000;
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
print "Raw return value : $status_raw\n";

if ($status_raw == 42) {
    print "SUCCESS: get_status_code returned 42\n";
} else {
    print "FAILURE: get_status_code returned $status_raw\n";
}

warn math_add(3, 4);

exit 0; # Stop here for now
