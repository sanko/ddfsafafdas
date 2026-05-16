#!/usr/bin/env perl
use v5.40;
use lib '../lib';
use Brocken::JIT;

my $source = <<'BROCKEN';
my $x = 10;
my $y = 25;
say "Multiplying " . $x . " by " . $y . "...";
my $z = $x * $y;
say $z;
BROCKEN

say "Compiling and Running JIT...";
my $jit = Brocken::JIT->new(standalone => 1);
my $res = $jit->compile_and_run($source);

if (defined $res) {
    # Untag Smi: (res >> 1)
    say "Final Result from JIT: " . ($res >> 1);
} else {
    say "JIT returned nothing (perhaps it exited via intrinsic_exit?)";
}
