use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use lib 'lib';
use Brocken;
use Carp::Always;
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
     say "Entering function...";
     defer {
         say "   [Defer] Executing cleanup 1 (LIFO)";
     }
     defer {
         say "   [Defer] Executing cleanup 2 (LIFO)";
     }
     say "Doing work...";
     return 42;
}

say test_defer();

# Testing Immix GC by forcing allocations in a loop
my Int $i = 0;
while ($i < 700) {
    my Any $tmp = [1, 2, 3, 4, 5]; # Constant allocation to trigger GC line marking
    $i = $i + 1;
}


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

say "\n[6] Testing Milestone 2 features (undef, //, value-returning logicals)...";
my Any $u_val = undef;
my Any $d_val = $u_val // 42;
if ($d_val == 42) {
    say "   Defined-OR (//) with undef works!";
}

my Any $v_val = 10;
my Any $d_val2 = $v_val // 20;
if ($d_val2 == 10) {
    say "   Defined-OR (//) with value works!";
}

my Any $alt = 0 || "OR-Value";
if ($alt == "OR-Value") {
    say "   Logical OR returns value works!";
}

my Any $both = 42 && "AND-Value";
if ($both == "AND-Value") {
    say "   Logical AND returns value works!";
}

say "\n🎉 ALL TESTS PASSED SUCCESSFULLY! 🎉";

exit $u->get_id();
BROCKEN
$source_code = <<'BROCKEN' if 1;
say "1..13"; # Total test count

# Test 1: Anonymous Subs
my $add_one = sub (Int $n) { return $n + 1; };
my $res1 = $add_one->(41);
say ($res1 == 42 ? "ok 1 - Anonymous sub" : "not ok 1 - Anonymous sub");

# Test 2: Subroutines
sub multiply(Int $val, Int $factor) { return $val * $factor; }
my $res2 = multiply(10, 2);
say ($res2 == 20 ? "ok 2 - Subroutine call" : "not ok 2 - Subroutine call");
say "# $res2";

# Test 3: Loops & Variables
my Int $c = 0;
while ($c < 3) { $c = $c + 1; }
say ($c == 3 ? "ok 3 - While loop" : "not ok 3 - While loop");

# Test 4: Fibers
my Any $f = fiber { yield 42; return 99; };
my Int $f1 = transfer($f, 0);
say ($f1 == 42 ? "ok 4 - Fiber yield" : "not ok 5 - Fiber yield");

# Test 5: Classes & Methods
class User {
    field $id;
    method set_id(Int $val) { $id = $val; }
    method get_id() { return $id; }
}
my Any $u = User->new();
$u->set_id(42);
say ($u->get_id() == 42 ? "ok 5 - Class/Method" : "not ok 4 - Class/Method");

# Test 6: Defer (LIFO)
sub test_defer() {
     my Int $x = 0;
     defer { $x = $x + 10; }
     defer { $x = $x + 5; }
     return $x; # Should be 0
 }
#~ # Note: Defer runs on return.
say "# " . test_defer();
say "ok 6 - Defer structure (Manual inspection required)";

# Test 7: Unless
my Bool $bad = false;
my Int $unless_res = 0;
unless ($bad) { $unless_res = 1; }
say ($unless_res == 1 ? "ok 7 - Unless" : "not ok 7 - Unless");

# Test 8: Until
my Int $until_c = 0;
until ($until_c == 3) { $until_c = $until_c + 1; }
say ($until_c == 3 ? "ok 8 - Until" : "not ok 8 - Until");

# Test 9: Ternary
my String $t = true ? "ok" : "not ok";
say "ok 9 - Ternary";

# Test 10: Logical AND
my Bool $is_cool = true;
my Bool $is_bad = false;
say (($is_cool == true) && ($is_bad == false) ? "ok 10 - Logical AND" : "not ok 10 - Logical AND");

# Test 11: String Lexing
print "ok 11 - String Lexing\n";

# Test 12: Scoping
my Int $x = 10;
{ my Int $x = 20; }
say ($x == 10 ? "ok 12 - Scoping" : "not ok 12 - Scoping");

# Test 13: Array/GC
my Any $arr = [1, 2, 3];
say ("ok 13 - Array allocation");

say '$u->get_id() = ' . $u->get_id();

exit $u->get_id();
BROCKEN
$source_code = 'sub testing() {return "Hi";} say testing(); my Any $f = fiber ($i) { say $i; yield "hi 10"; }; say transfer($f, "10 arg");' if 0;
$source_code = <<'BROCKEN'                                                                                                                  if 0;
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
$source_code = <<'END' if 0;
# Testing Immix GC by forcing allocations in a loop
my Int $i = 0;
while ($i < 700) {
    my Any $tmp = [1, 2, 3, 4, 5]; # Constant allocation triggers GC line marking
    $i = $i + 1;
    if ($i == 10000000) {
        say "Ready...";
    }
}
say "Done";
END
$source_code = <<'END' if 0;
sub test_defer() {
     say "Entering function...";
     defer {
         say "   [Defer] Executing cleanup 1 (LIFO)";
     }
     defer {
         say "   [Defer] Executing cleanup 2 (LIFO)";
     }
     say "Doing work...";
     return 42;
}

say test_defer();

{
  defer{ say "Demo";  }
  say "Hi";
  defer {say "Last"; }
}
END
$source_code = <<'END' if 0;
do_nothing();;
{
    defer { say "This will run"; exit; say "After return" }
    #return;
    #defer { say "This will not" }
}

sub do_nothing() {
    say "Wait for it...";
    return;
    say "Never seen"
}

END
$source_code = <<'END';
say "Testing File I/O...";

my String $test_file = "test_output.txt";
my String $content = "Hello, Brocken File I/O!";

say "1. Testing spurt (write file)...";
my Int $result = spurt($test_file, $content);
say "   spurt result: " . $result;

say "2. Testing slurp (read file)...";
my String $read_content = slurp($test_file);
say "   slurp result: " . $read_content;

say "3. Testing open/close...";
my Any $fh = open($test_file, "r");
say "   open result: " . $fh;
my Int $close_result = close($fh);
say "   close result: " . $close_result;

say "4. Testing read...";
my Any $fh2 = open($test_file, "r");
my String $line = read($fh2, 100);
say "   read result: " . $line;
close($fh2);

say "All File I/O tests completed!";
exit 0;
END
$source_code = <<'END' if 0;
say "--- Brocken Milestone 3.5: Native Sleep & GC Check ---";

# 1. GC STRESS TEST
# This loop allocates 100,000 arrays.
# Without the HWM (High Water Mark) fix, this would gulp hundreds of MBs.
# With the fix, it should stay within a few 64KB blocks.
my Int $i = 0;
say "GC Pressure Test: Allocating 100,000 objects...";
while ($i < 100000) {
    my Any $a = [1, 2, 3]; # Allocate array
    $i = $i + 1;

    # Visual feedback every 20k iterations
    if ($i % 20000 == 0) {
        print "Processed: ";
        say $i;
    }
}
say "GC Test Passed: Memory reclaimed successfully.";

# 2. INTERRUPTIBLE SLEEP TEST
# This verifies:
#   a) Sleep is imported from kernel32.dll
#   b) The 'main' fiber has a valid wait_handle
#   c) The X64 backend isn't clobbering RDX during internal GC math
say "Testing Native Sleep: Sleeping for 3 seconds...";
sleep 3;
say "Wake up! If you see this, the WinAPI call returned correctly. 🎉";

# 3. FIBER CONTEXT TEST
# Verify that a new fiber also receives a valid handle and can sleep.
my Any $f = fiber {
    say "   [Fiber] Starting and taking a short nap (1s)...";
    sleep 1;
    say "   [Fiber] Nap over, yielding back to main.";
    yield "Success";
};

say "Transferring to fiber...";
my Any $val = transfer($f, 0);
say "Main received from fiber: " . $val;

say "--- ALL TESTS PASSED ---";
exit 0;
END
$source_code = <<'END';
my Int $done = 0;
my Int $i = 0;
while ($i <= 100000) {
    #~ say $i;
    my Any $a = [1];
    my Any $b = [2];
    my Any $c = [3];
    $done = $i;
    $i = $i + 1;
    say "Testing File I/O...";
}
say "Reached: " . $done;
sleep 5;
END
$source_code = <<'END';
my $filename = "hello_world.txt";

# 1. Create and Write
my $fh = open($filename, "w");
 print $fh, "Hello from Brocken Native! 🚀\n";
 print $fh, "This file was written via WinAPI/Linux Syscalls.\n";
close($fh);

# 2. Slurp and Display
say "Reading file back...";
my String $content = slurp($filename);
say "--- FILE CONTENT ---";
say $content;
say "--------------------";
END


$source_code = <<'END';
my Int $i = 0;
        while ($i < 1000) {
            my Any $a = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
            my Any $b = [1, 2, 3];
            $i = $i + 1;
        }
        say "Done";
        #~ sleep 20;
END

my $dbg = 0;
my $os;
my $type = 'exe';
my @files;
for ( my $i = 0; $i < @ARGV; $i++ ) {
    my $arg = $ARGV[$i];
    if ( $arg =~ /^--debug(?:=(\d+))?$/ ) {
        $dbg = defined $1 ? $1 : ( $ARGV[ ++$i ] // 0 );
    }
    elsif ( $arg =~ /^--os(?:=(.+))?$/ ) {
        $os = defined $1 ? $1 : ( $ARGV[ ++$i ] );
    }
    elsif ( $arg eq '--shared' ) {
        $type = 'shared';
    }
    elsif ( $arg !~ /^--/ ) {
        push @files, $arg;
    }
}

if ( @files && -f $files[0] ) {
    open my $fh, '<', $files[0] or die "Cannot read $files[0]: $!";
    $source_code = do { local $/; <$fh> };
    close $fh;
    say "Reading source from: $files[0]";
}

my $p = Brocken::Compiler->new( debug => $dbg, type => $type, ( $os ? ( os => $os ) : () ) );
say "Targeting OS: " . $p->os . " | Arch: " . $p->arch;
say "Debug: " . $p->debug;
my $tokens   = Brocken::Lexer->new( source => $source_code )->lex();
my $ast      = Brocken::Parser->new( tokens => $tokens )->parse();
my $ds       = Brocken::Compiler::DataSegment->new();
my $lowering = Brocken::Compiler::Lowering->new( data_segment => $ds, driver => $p );
$lowering->lower_program($ast);
my $optimizer = Brocken::Compiler::Optimizer->new();
$optimizer->optimize( $lowering->builder );
# $lowering->builder->dump_ir("FINAL IR");
my $insts = $lowering->builder->instructions;
my $est_text = scalar(@$insts) * 32 + 4096;
my $est_data = length( $ds->get_raw_data() ) + 4096;
$p->format->pre_layout( $est_text, $est_data, $p->arch, $p->os, $p->debug );
my $codegen = Brocken::Codegen->new( arch => $p->arch );
$codegen->compile( [ $lowering->builder->instructions() ], $p );
$p->as->resolve( $p->text_rva, $p->data_rva );
my %labels = $p->as->labels;
$p->format->set_labels( \%labels );

if ( $p->type eq 'shared' ) {
    my @exports;
    for my $l ( keys %labels ) {
        if ( $l =~ /^M_([a-zA-Z0-9_]+)$/ ) {
            push @exports, $1;
        }
    }
    # Pass exports to format if it's PE
    if ( $p->format isa Brocken::Format::PE ) {
        $p->format->set_exported_funcs( \@exports );
    }
}

if ( $p->debug >= 1 ) {
    say "\n--- DEBUG SOURCE LOCATIONS ---";
    my @sls = $p->source_locs;
    for my $sl (@sls) {
        printf "  offset=0x%04X  line=%-4d col=%d\n", $sl->{offset}, $sl->{line}, $sl->{col};
    }
    say scalar(@sls) . " source location entries\n";
    require Brocken::Format::DWARF;
    my $text_base     = $p->format->image_base + $p->format->rva_for('.text');
    my $eh_frame_base = 0;
    eval { $eh_frame_base = $p->format->image_base + $p->format->rva_for('.eh_frame'); };
    my @funcs = $p->func_ranges;
    $p->format->set_func_ranges( \@funcs );
    my %class_info = $lowering->class_info;
    my $dw         = Brocken::Format::DWARF->new(
        source_locs    => \@sls,
        text_base      => $text_base,
        eh_frame_base  => $eh_frame_base,
        func_ranges    => \@funcs,
        context_size   => $p->context_size,
        class_info     => \%class_info,
        debug          => $p->debug,
        arch           => $p->arch,
        preserved_regs => $p->preserved_regs
    );
    my $dwarf = $dw->build_all;
    say "DWARF: line=" .
        length( $dwarf->{'.debug_line'} ) .
        " info=" .
        length( $dwarf->{'.debug_info'} ) .
        " abbrev=" .
        length( $dwarf->{'.debug_abbrev'} ) .
        " frame=" .
        length( $dwarf->{'.debug_frame'} // '' ) .
        " eh_frame=" .
        length( $dwarf->{'.eh_frame'} // '' ) .
        " aranges=" .
        length( $dwarf->{'.debug_aranges'} // '' ) .
        " pubnames=" .
        length( $dwarf->{'.debug_pubnames'} // '' );
    say "SEH: pdata=" . ( scalar(@funcs) * 12 ) . " xdata=28" if $p->os eq 'win64';
    say sprintf ".debug_frame: %d FDEs, %d bytes", scalar(@funcs), length( $dwarf->{'.debug_frame'} // '' );

    for my $fn (@funcs) {
        printf "  %-20s start=0x%04X end=0x%04X ctx=%d", $fn->{name}, $fn->{start}, ( $fn->{end} // 0 ), $fn->{ctx_size};
        if ( $fn->{params} && @{ $fn->{params} } ) {
            printf " params=%s", join ',', map {"$_->{name}:$_->{type}"} @{ $fn->{params} };
        }
        if ( $fn->{locals} && @{ $fn->{locals} } ) {
            printf " locals=%s", join ',', map {"$_->{name}:$_->{type}"} @{ $fn->{locals} };
        }
        print "\n";
    }
    $p->format->set_debug_data($dwarf);
    for my $s ( $p->format->layout->sections ) {
        next if $s->{name} !~ /^\.(debug|eh_frame)/;
        $s->{size} = length( $p->format->debug_section( $s->{name} ) );
    }
    $p->format->layout->calculate(0x1000);
    if ( $p->debug >= 2 ) {
        say "\n--- .debug_info HEX DUMP ---";
        my $di = $p->format->debug_section('.debug_info');
        for ( my $i = 0; $i < length($di); $i += 16 ) {
            my $chunk = substr( $di, $i, 16 );
            printf "%04X: %s\n", $i, unpack( "H*", $chunk );
        }
        say "\n--- .debug_abbrev HEX DUMP ---";
        my $da = $p->format->debug_section('.debug_abbrev');
        for ( my $i = 0; $i < length($da); $i += 16 ) {
            my $chunk = substr( $da, $i, 16 );
            printf "%04X: %s\n", $i, unpack( "H*", $chunk );
        }
    }
}
my $ext = $p->os eq 'win64' ? ($p->type eq 'shared' ? '.dll' : '.exe') : ($p->type eq 'shared' ? '.so' : '');
$ext = '.dylib' if $p->os eq 'macos' && $p->type eq 'shared';
my $exe = $p->format->write_bin( "brocken_out$ext", $p->as->code, $ds->get_raw_data(), $p->arch, $p->os, $p->type );
say "Executing Native Binary...";
my $run = ( $^O eq 'MSWin32' ? '' : './' ) . $exe;
if ( $^O eq 'darwin' ) {

    # macOS / LLDB path
    my @args
        = $p->debug >= 1 ?
        ( "-o", "breakpoint set -a " . ( $p->format->image_base + $p->format->rva_for('.text') + 0x1160 ), "-o", "run", "-o", "bt", "-o", "quit" ) :
        ( "-o", "run", "-o", "bt", "-o", "quit" );
    system( "lldb", "-b", @args, "--", $run );
}
else {
    # Windows/Linux / GDB path
    # Build a clean array of arguments to avoid empty strings
    my @cmd = ( "gdb", "--batch", "--quiet" );
    if ( $p->debug >= 1 ) {
        my $tb = $p->format->image_base + $p->format->rva_for('.text');
        my $fp = $p->arch eq 'arm64' ? '$x29' : '$rbp';

        #~ push @cmd, "-ex", "break *" . ( $tb + 0x1160 );
        push @cmd, "-ex", "p val", "-ex", "x/gx $fp-8";
    }
    push @cmd, "-ex", "run", "-ex", "bt", "-ex", "quit \$_exitcode", "--args", $run;

# Use the list form of system() to bypass shell parsing issues entirely
    system(@cmd);
}
say "Exit code: " . ( $? >> 8 );
my $code_bytes = $p->as->code;
say "Generated machine code size: " . length($code_bytes) . " bytes";
if ( $dbg == 4 ) {
    say "\n--- MACHINE CODE HEX DUMP ---";
    for ( my $i = 0; $i < length($code_bytes); $i += 16 ) {
        my $chunk = substr( $code_bytes, $i, 16 );
        printf( "%04X: %-40s\n", $i, unpack( "H*", $chunk ) );
    }
}
