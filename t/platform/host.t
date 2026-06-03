use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib', '../../lib';
use Brocken::Host;
#
subtest 'os() returns a known value' => sub {
    my $os = Brocken::Host::os();
    like $os, qr/^(win64|macos|linux|freebsd|netbsd|openbsd|dragonfly|haiku|midnightbsd|solaris)$/, "os($os) is a recognised platform";
};
subtest 'arch() returns a known value' => sub {
    my $arch = Brocken::Host::arch();
    like $arch, qr/^(x64|arm64|arm|riscv64)$/, "arch($arch) is a recognised architecture";
};
subtest 'is_windows() matches os()' => sub {
    is !!Brocken::Host::is_windows(), !!( Brocken::Host::os() eq 'win64' ), 'is_windows is true iff os is win64';
};
subtest 'is_unix() is the inverse of is_windows()' => sub {
    is !!Brocken::Host::is_unix(), !Brocken::Host::is_windows(), 'is_unix is the inverse of is_windows';
};
subtest 'is_x64() matches arch()' => sub {
    is !!Brocken::Host::is_x64(), !!( Brocken::Host::arch() eq 'x64' ), 'is_x64 is true iff arch is x64';
};
subtest 'is_arm() matches arch() pattern' => sub {
    is !!Brocken::Host::is_arm(), !!( Brocken::Host::arch() =~ /^arm/ ), 'is_arm is true iff arch starts with arm';
};
subtest 'is_riscv() matches arch() pattern' => sub {
    is !!Brocken::Host::is_riscv(), !!( Brocken::Host::arch() =~ /riscv/ ), 'is_riscv is true iff arch contains riscv';
};
subtest 'OS map covers $^O' => sub {
    ok exists $Brocken::Host::OS_MAP{$^O}, "\$^O ($^O) is in OS_MAP";
};
subtest 'Compiler uses Brocken::Host for default arch' => sub {
    require Brocken::Compiler;
    my $c = Brocken::Compiler->new( os => undef, arch => undef );
    is $c->os,   Brocken::Host::os(),   'Compiler defaults to Host::os()';
    is $c->arch, Brocken::Host::arch(), 'Compiler defaults to Host::arch()';
};
subtest 'Compiler uses Brocken::Host for default arch (Pipeline)' => sub {
    require Brocken::Compiler::Pipeline;
    my $p = Brocken::Compiler::Pipeline->new( os => undef, arch => undef );
    is $p->os,   Brocken::Host::os(),   'Pipeline defaults to Host::os()';
    is $p->arch, Brocken::Host::arch(), 'Pipeline defaults to Host::arch()';
};
subtest 'Compiler override still works' => sub {
    require Brocken::Compiler;
    my $c = Brocken::Compiler->new( os => 'freebsd', arch => 'arm64' );
    is $c->os,   'freebsd', 'os override sticks';
    is $c->arch, 'arm64',   'arch override sticks';
};
#
done_testing;
