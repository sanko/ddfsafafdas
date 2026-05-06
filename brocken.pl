use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use lib 'lib';
use Brocken;
$|++;
my $source_code = <<'BROCKEN';
my $add_one = sub (Int $n) {
    return $n + 1;
};

my $val = 41;
my $res = $add_one->($val);

say "The answer is: $res";

 if ($res == 42) {
     say "Anonymous call works! 🎉";
 }

sub multiply(Int $val, Int $factor) {
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

sub test_defer() {
    #~ say "Entering function...";
    #~ defer {
        #~ say "   [Defer] Executing cleanup 1 (LIFO)";
    #~ }
    #~ defer {
        #~ say "   [Defer] Executing cleanup 2 (LIFO)";
    #~ }
    #~ say "Doing work...";
    #~ return 42;
}

#~ say test_defer();

#~ # Testing Immix GC by forcing allocations in a loop
#~ my Int $i = 0;
#~ while ($i < 100) {
    #~ my Any $tmp = [1, 2, 3, 4, 5]; # Constant allocation to trigger GC line marking
    #~ $i = $i + 1;
#~ }


say "\n[5] Testing new Spec features (unless, until, ternary, logical)...";
my Bool $is_cool = true;
my Bool $is_bad  = false;

unless ($is_bad) {
    say "   Unless block works!";
}

my Int $c = 0;
until ($c == 3) {
    $c = $c + 1;
}
if ($c == 3) {
    say "   Until loop works!";
}

if ($is_cool && !$is_bad) {
    say "   Logical AND short-circuit works!";
}

my String $t_res = $is_cool ? "   Ternary works!" : "   Ternary Failed!";
say $t_res;

say "\n🎉 ALL TESTS PASSED SUCCESSFULLY! 🎉";

exit $u->get_id();
BROCKEN

$source_code = 'sub testing() {return "Hi";} say testing(); my Any $f = fiber { yield 10; }; say transfer($f, "10");';

$source_code = <<'BROCKEN';
sub testing() { return "Hi"; }
say testing();

# Fiber now accepts a parameter $x!
my Any $f = fiber (Any $x) {
    print "Fiber received: ";
    say $x;
    yield 42;
};

say "Main sending 10...";
my Int $res = transfer($f, "ten 10");
print "Main received from fiber: ";
say $res;
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
system( 'gdb --batch -ex "run" -ex "bt" -ex "info registers" -ex "x/20i $pc-40" -ex "quit $_exitcode" --args ' . $run );
say "Exit code: " . ( $? >> 8 );
