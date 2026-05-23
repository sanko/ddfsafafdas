use v5.40;
use lib 'lib';
use Brocken::TestHelpers qw(test_brocken);
use Test2::V0;

# Test Native OS Threading (spawn_thread)
test_brocken(
    name   => 'Parallel OS Threads',
    source => q{
        sub worker() {
            say "Background thread running.";
            my Int $acc = 0;
            for my $i (1 .. 10) { $acc = $acc + $i; }
            say "Worker result: " . $acc;
        }

        say "Main: Spawning thread...";
        my $t = spawn_thread(sub () { worker(); });
        
        # Give the background thread some time to execute
        sleep(1);
        say "Main: Finished.";
    },
    expected => qr/Main: Spawning thread\.\.\.\r?\nBackground thread running\.\r?\nWorker result: 55\r?\nMain: Finished\./
);
done_testing;
