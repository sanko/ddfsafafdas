#!/usr/bin/env perl
use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use lib 'lib';
use Brocken;
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
 # $y should be 20. Return 20 + 22 = 42.
say "Blast off!";

class User {
    field $id;
    field $status;

    method set_id(Int $val) {
        $id = $val;
        $status = 1;
    }

    method get_id() {
        return $id;
    }
}

say "Booting Brocken Runtime... ❤️😭";

my Any $u = User->new();
$u->set_id(42);

say "Brocken executed successfully!";

# --- [4] FIBERS (COROUTINES) ---
say "\n[4] Testing Fibers (Cooperative Multitasking)...";
my Any $gen = fiber {
    say "   [Fiber] Starting up!";
    yield 42;
    say "   [Fiber] Resumed! Yielding 84...";
    yield 84;
    say "   [Fiber] Wrapping up execution!";
    return 99;
};

say "Main: Transferring to fiber (1st time)...";
my Int $f1 = transfer($gen, 0);
print "Main: Received from fiber: ";
say $f1;

say "Main: Transferring to fiber (2nd time)...";
my Int $f2 = transfer($gen, 0);
print "Main: Received from fiber: ";
say $f2;

say "Main: Transferring to fiber (3rd and final time)...";
my Int $f3 = transfer($gen, 0);
print "Main: Received from fiber return: ";
say $f3;

say "\n🎉 ALL TESTS PASSED SUCCESSFULLY! 🎉";


exit $u->get_id();
BROCKEN
say "Bootstrapping Brocken...";
my $p = Brocken::Compiler->new();
say "Targeting OS: " . $p->os . " | Arch: " . $p->arch;
my $tokens   = Brocken::Lexer->new( source => $source_code )->lex();
my $ast      = Brocken::Parser->new( tokens => $tokens )->parse();
my $ds       = Brocken::Compiler::DataSegment->new();
my $lowering = Brocken::Compiler::Lowering->new( data_segment => $ds, driver => $p );
$lowering->lower_program($ast);
my $optimizer = Brocken::Compiler::Optimizer->new();
$optimizer->optimize( $lowering->builder );
$lowering->builder->dump_ir("FINAL IR");
my $est_text = scalar( $lowering->builder->instructions ) * 32 + 4096;
my $est_data = length( $ds->get_raw_data() ) + 4096;
$p->format->pre_layout( $est_text, $est_data, $p->arch, $p->os );
my $codegen = Brocken::Codegen->new( arch => $p->arch );
$codegen->compile( [ $lowering->builder->instructions() ], $p );
$p->as->resolve();
my $ext = $p->os eq 'win64' ? '.exe' : '';
my $exe = $p->format->write_bin( "brocken_out$ext", $p->as->code, $ds->get_raw_data(), $p->arch, $p->os );
say "Executing Native Binary...";
my $run = $^O eq 'MSWin32' ? $exe : "./$exe";
system( 'gdb --batch -ex "run" -ex "bt" -ex "info registers" -ex "x/20i $pc-40" --args ' . $run );
say "Exit code: " . ( $? >> 8 );
