#!/usr/bin/env perl
use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use lib 'lib';
use Brocken;
use Pulse;
$|++;
my $source_code = <<'BROCKEN';
# 1. Method Definition (Milestone 3!)
method multiply(Int $val, Int $factor) {
    say "Multiplying...";
    return $val * $factor;
}

my Int $countdown = 3;
while ($countdown > 0) {
    if ($countdown == 2) {
        say "Almost there...";
    } else {
        say "Counting...";
    }
    $countdown = $countdown - 1;
}

my Int $x = 10;
{
    my Int $x = 32; # Inner scope shadows outer scope
}

say "Blast off!";
# 2. Map Loop Fusion Test
my Any $arr = 0;
my Any $fused = map { $_ - 5 } map { $_ * 2 } map { $_ + 1 } $arr;

# 3. Main script logic using method call
say "Brocken Milestone 3 Complete! 🚀";

print "你好";

my Int $y = multiply($x, 2); # Calls our method above!
return $y;
# $y should be 20. Return 20 + 22 = 42.
say "Blast off!";
return $y + 22;
BROCKEN
$source_code = <<'BROCKEN';
# 1. State Variable Test (Milestone 5)
method generate_id() {
    state Int $counter = 0;
    $counter = $counter + 1;
    return $counter;
}

say "--- Testing Isolate-Local State ---";
say generate_id(); # 1
say generate_id(); # 2
say generate_id(); # 3

# 2. GC Region Allocator Test (Milestone 5)
say "--- Testing Region Heap Allocation ---";
my Int $i = 0;
while ($i < 10000) {
    # Each array uses 48 bytes. 10,000 * 48 = 480KB.
    # This proves the Region Allocator successfully requests
    # new 64KB OS memory chunks behind the scenes!
    my Any $tmp = [1, 2, 3];
    $i = $i + 1;
}
say "Survived 10,000 dynamic heap allocations!";

# 3. Futhark Fusion
my Any $arr = 0;
my Any $fused = map { $_ - 5 } map { $_ * 2 } map { $_ + 1 } $arr;
say "Milestone 5 Complete! 🚀";
BROCKEN
say "Bootstrapping Brocken...";
my $p = Pulse::Compiler->new();
say "Targeting OS: " . $p->os . " | Arch: " . $p->arch;
my $tokens   = Brocken::Lexer->new( source => $source_code )->lex();
my $ast      = Brocken::Parser->new( tokens => $tokens )->parse();
my $ds       = Brocken::Compiler::DataSegment->new();
my $lowering = Brocken::Compiler::Lowering->new( data_segment => $ds );
$lowering->lower_program($ast);
my $optimizer = Brocken::Compiler::Optimizer->new();
$lowering->builder->dump_ir('ORIGINAL IR');
$optimizer->optimize( $lowering->builder );
my $codegen = Brocken::Codegen->new( arch => $p->arch );
$codegen->compile( [ $lowering->builder->instructions() ], $p );
$p->as->resolve();
$lowering->builder->dump_ir("OPTIMIZED IR");
my $exe = $p->format->write_bin( 'brocken_out' . ( $p->os eq 'win64' ? '.exe' : '' ), $p->as->code, $ds->get_raw_data(), $p->arch, $p->os );
say "Executing Native Binary...";
system( $^O eq 'MSWin32' ? $exe : "./$exe" );
say "Exit code: " . ( $? >> 8 );
