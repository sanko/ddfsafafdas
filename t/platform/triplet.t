use v5.40;
use utf8;
use feature 'class';
use Test2::V0;
no warnings 'portable', 'experimental::class';
use lib 'lib', '../../lib';
use Brocken::Triplet;
#
subtest 'GNU full triplets' => sub {
    my %cases = (
        'x86_64-pc-linux-gnu'         => { arch => 'x64',   os => 'linux' },
        'aarch64-linux-gnu'           => { arch => 'arm64', os => 'linux' },
        'x86_64-apple-darwin'         => { arch => 'x64',   os => 'macos' },
        'aarch64-apple-darwin'        => { arch => 'arm64', os => 'macos' },
        'x86_64-w64-windows-gnu'      => { arch => 'x64',   os => 'win64' },
        'aarch64-w64-windows-msvc'    => { arch => 'arm64', os => 'win64' },
        'x86_64-freebsd14.1'          => { arch => 'x64',   os => 'freebsd' },
        'aarch64-netbsd10.0'          => { arch => 'arm64', os => 'netbsd' },
        'x86_64-openbsd7.8'           => { arch => 'x64',   os => 'openbsd' },
        'x86_64-solaris2.11'          => { arch => 'x64',   os => 'solaris' },
        'x86_64-unknown-dragonfly6.4' => { arch => 'x64',   os => 'dragonfly' },
        'x86_64-pc-solaris2.11'       => { arch => 'x64',   os => 'solaris' },
    );
    for my $triplet ( sort keys %cases ) {
        my $p   = Brocken::Triplet->new($triplet);
        my $exp = $cases{$triplet};
        is $p->arch, $exp->{arch}, "$triplet → arch=$exp->{arch}";
        is $p->os,   $exp->{os},   "$triplet → os=$exp->{os}";
    }
};
subtest 'Brocken native format (<os>-<arch>)' => sub {
    my %cases = (
        'linux-x64'     => { arch => 'x64',   os => 'linux' },
        'win64-arm64'   => { arch => 'arm64', os => 'win64' },
        'macos-x64'     => { arch => 'x64',   os => 'macos' },
        'freebsd-arm64' => { arch => 'arm64', os => 'freebsd' },
        'solaris-x64'   => { arch => 'x64',   os => 'solaris' },
        'dragonfly-x64' => { arch => 'x64',   os => 'dragonfly' },
    );
    for my $triplet ( sort keys %cases ) {
        my $p   = Brocken::Triplet->new($triplet);
        my $exp = $cases{$triplet};
        is $p->arch, $exp->{arch}, "$triplet → arch=$exp->{arch}";
        is $p->os,   $exp->{os},   "$triplet → os=$exp->{os}";
    }
};
subtest 'Reverse (<arch>-<os>) works via GNU parser' => sub {
    my %cases = (
        'arm64-linux' => { arch => 'arm64', os => 'linux' },
        'x64-win64'   => { arch => 'x64',   os => 'win64' },
        'x64-freebsd' => { arch => 'x64',   os => 'freebsd' },
    );
    for my $triplet ( sort keys %cases ) {
        my $p   = Brocken::Triplet->new($triplet);
        my $exp = $cases{$triplet};
        is $p->arch, $exp->{arch}, "$triplet → arch=$exp->{arch}";
        is $p->os,   $exp->{os},   "$triplet → os=$exp->{os}";
    }
};
subtest 'Vendor and ABI extraction' => sub {
    my $p = Brocken::Triplet->new('x86_64-pc-linux-gnu');
    is $p->vendor, 'pc',  'vendor is pc';
    is $p->abi,    'gnu', 'abi is gnu';
    $p = Brocken::Triplet->new('aarch64-w64-windows-msvc');
    is $p->vendor, 'w64',  'vendor is w64';
    is $p->abi,    'msvc', 'abi is msvc';
    $p = Brocken::Triplet->new('arm64-linux');
    is $p->vendor, undef, 'no vendor for short form';
    is $p->abi,    undef, 'no abi for short form';
};
subtest 'Brocken::Compiler accepts triplet' => sub {
    require Brocken::Compiler;
    my $c = Brocken::Compiler->new( triplet => 'x86_64-linux-gnu' );
    is $c->arch, 'x64',   'compiler arch from triplet';
    is $c->os,   'linux', 'compiler os from triplet';
};
subtest 'Brocken::Compiler::Pipeline accepts triplet' => sub {
    require Brocken::Compiler::Pipeline;
    my $p = Brocken::Compiler::Pipeline->new( triplet => 'aarch64-w64-windows-msvc' );
    is $p->arch, 'arm64', 'pipeline arch from triplet';
    is $p->os,   'win64', 'pipeline os from triplet';
};
subtest 'Explicit arch/os takes priority over triplet' => sub {
    require Brocken::Compiler;
    my $c = Brocken::Compiler->new( triplet => 'x86_64-linux-gnu', arch => 'arm64', os => 'freebsd' );
    is $c->arch, 'arm64',   'explicit arch overrides triplet';
    is $c->os,   'freebsd', 'explicit os overrides triplet';
};
subtest 'Broken or empty triplet falls back to Host detection' => sub {
    require Brocken::Compiler;
    my $c = Brocken::Compiler->new( triplet => '', arch => undef, os => undef );
    require Brocken::Host;
    is $c->arch, Brocken::Host::arch(), 'empty triplet → Host::arch()';
    is $c->os,   Brocken::Host::os(),   'empty triplet → Host::os()';
};
subtest 'as_string formats correctly' => sub {
    my $p = Brocken::Triplet->new('x86_64-linux-gnu');
    is $p->as_string, 'x64-linux-gnu', 'as_string normalizes arch';
    $p = Brocken::Triplet->new('aarch64-linux-gnu');
    is $p->as_string, 'arm64-linux-gnu', 'as_string for arm64';
    $p = Brocken::Triplet->new('arm64-linux');
    is $p->as_string, 'arm64-linux', 'as_string short form';
};
#
done_testing;
