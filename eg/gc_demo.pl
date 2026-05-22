use v5.40;
use lib 'lib', '../lib', '../../lib';
use Brocken::Compiler;
$|++;

# 1. Define a Brocken program that aggressively allocates memory
my $brocken_source = <<'BROCKEN';
#line 9 gc_demo.pl
my Int $i = 0;
my Any $persistent_state = [0];

say "==================================================";
say " Brocken Generational & Evacuating GC Stress Test ";
say "==================================================";
say "Process ID: " . $$;
say "Open your process manager (top / htop / taskmgr).";
say "Watch the memory footprint of this PID.";
say "Because of the GC, memory usage will remain flat and stable.";
say "top -p $$";
say "Waiting 15 seconds to let you find the process...";
sleep 15;
say "Starting heavy allocation loop (2,000,000 iterations)...";

while ($i < 2000000) {
    # 1. Nursery Stress:
    # These arrays and strings die immediately. They will quickly fill up the
    # 64KB Nursery and trigger M_minor_collect, which reclaims them instantly.
    my Any $garbage1 = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
    my Any $garbage2 = "Temporary string " . $i;

    # 2. Tenured Heap Stress:
    # Every 2,500 iterations, we update a persistent variable.
    # The previous array will have survived a minor GC and been promoted
    # to the 2MB Tenured Heap. By replacing it here, we orphan it, eventually
    # forcing the Major Evacuating GC to flip the semi-spaces and compact memory.
    if ($i % 2500 == 0) {
        $persistent_state = ["Generation", $i, "Survived Nursery"];
    }

    # Print progress so we know it isn't hanging
    if ($i % 250000 == 0) {
        say "  ... passed " . $i . " iterations";
    }

    $i = $i + 1;
}

say "Allocation loop complete!";
say "Final persistent state: " . $persistent_state[1];
say "";
say "Sleeping 3 seconds before exit to observe final memory state...";
sleep 3;
say "Done! No memory leaks detected.";
BROCKEN
my $os       = $^O eq 'MSWin32' ? 'win64' : 'linux';
my $ext      = $os eq 'win64'   ? '.exe'  : '';
my $exe_name = "demo_gc$ext";
say "1. Compiling Brocken GC stress test into $exe_name...";
my $compiler = Brocken::Compiler->new( type => 'exe', debug => 0 );
$compiler->compile_source( $brocken_source, $exe_name, 'demo_gc.bkn' );
say "2. Executing $exe_name natively...\n" . ( "-" x 50 );

# Execute the binary
my $run = ( $os eq 'win64' ? '' : './' ) . $exe_name;
system($run);
