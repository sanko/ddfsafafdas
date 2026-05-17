#!/usr/bin/env perl
# eg/cross_compile.pl
# Demonstrates cross-compiling Brocken source code into standalone native
# executables for multiple target platforms.
use v5.40;
use lib '../lib';
use Brocken::Compiler;
my $source = <<'BROCKEN';
say "Hello! This executable was cross-compiled by Brocken!";
BROCKEN
my @targets = (
    { os => 'linux', arch => 'x64', ext => '' }, { os => 'win64', arch => 'x64', ext => '.exe' }, { os => 'freebsd', arch => 'x64', ext => '' },

    # { os => 'macos',   arch => 'x64', ext => '' }, # Pending macOS formatter completion
);
say "Starting Cross-Compilation (Executables)...";
for my $target (@targets) {
    my $file = "cross_hello_$target->{os}_$target->{arch}$target->{ext}";
    say " -> Building $file";
    my $compiler = Brocken::Compiler->new( type => 'exe', os => $target->{os}, arch => $target->{arch} );
    $compiler->compile_source( $source, $file );
}
say "Done! Check your directory for the generated binaries.";
