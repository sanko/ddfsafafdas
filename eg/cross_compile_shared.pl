use v5.40;
use lib '../lib';
use Brocken::Compiler;

my $source = <<'BROCKEN';
sub get_magic_number() {
    return 42;
}
BROCKEN

my @targets = (
    { os => 'linux',   arch => 'x64', ext => '.so' },
    { os => 'win64',   arch => 'x64', ext => '.dll' },
    { os => 'freebsd', arch => 'x64', ext => '.so' },
);

say "Starting Cross-Compilation (Shared Libraries)...";

for my $target (@targets) {
    my $file = "magic_lib_$target->{os}_$target->{arch}$target->{ext}";
    say " -> Building $file";

    my $compiler = Brocken::Compiler->new(
        type => 'shared',
        os   => $target->{os},
        arch => $target->{arch}
    );

    $compiler->compile_source($source, $file);
}

say "Done! Generated shared libraries ready for distribution.";
