package Brocken::Triplet;
use v5.40;
use strict;
use warnings;
no warnings 'portable';
my %ARCH_MAP = (
    x64     => 'x64',
    x86_64  => 'x64',
    amd64   => 'x64',
    i386    => 'x64',
    i486    => 'x64',
    i586    => 'x64',
    i686    => 'x64',
    aarch64 => 'arm64',
    arm64   => 'arm64',
    armv8   => 'arm64',
    armv8l  => 'arm64',
    armv7l  => 'arm',
    armv7   => 'arm',
    arm     => 'arm',
    riscv64 => 'riscv64',
    riscv   => 'riscv64',
);
my %OS_MAP;
my @OS_PATTERNS;

BEGIN {
    %OS_MAP = qw(
        linux      linux
        freebsd    freebsd
        netbsd     netbsd
        openbsd    openbsd
        dragonfly  dragonfly
        darwin     macos
        macos      macos
        solaris    solaris
        sunos      solaris
        illumos    solaris
        haiku      haiku
        midnightbsd midnightbsd
        windows    win64
        win32      win64
        win64      win64
        cygwin     win64
        mingw      win64
        msvcrt     win64
    );
    @OS_PATTERNS = sort { length($b) <=> length($a) } keys %OS_MAP;
}

sub new ( $class, $triplet ) {
    my $self = bless { triplet => $triplet }, $class;
    $self->_parse;
    return $self;
}
sub triplet ($self) { $self->{triplet} }
sub os      ($self) { $self->{os} }
sub arch    ($self) { $self->{arch} }
sub abi     ($self) { $self->{abi} }
sub vendor  ($self) { $self->{vendor} }

sub as_string ($self) {
    join '-', grep defined, $self->{arch}, $self->{os}, $self->{abi};
}

sub _parse ($self) {
    my $t = $self->{triplet};
    return unless defined $t && length $t;
    $t = lc $t;

    # Brocken native format: <os>-<arch> (e.g. linux-arm64)
    if ( $t =~ /^(win64|macos|linux|freebsd|netbsd|openbsd|dragonfly|haiku|midnightbsd|solaris|illumos)-(x64|arm64|riscv64|arm)$/ ) {
        $self->{os}   = $1;
        $self->{arch} = $2;
        return;
    }

    # Split on dash
    my @parts = split /-/, $t;

    # First part is always the architecture
    if ( my $a = $ARCH_MAP{ $parts[0] } ) {
        $self->{arch} = $a;
        shift @parts;
    }

    # The remaining parts: look for known OS keywords
    # Vendor (a single short word) is skipped — it's usually "pc", "unknown", "w64", etc.
    for my $i ( 0 .. $#parts ) {
        if ( my $os = $self->_match_os( $parts[$i] ) ) {
            $self->{os} = $os;

            # Anything before the OS keyword is the vendor (if we haven't consumed it as arch)
            if ( $i > 0 && !$self->{vendor} ) {
                $self->{vendor} = join '-', @parts[ 0 .. $i - 1 ];
            }

            # Anything after is the ABI
            if ( $i < $#parts ) {
                $self->{abi} = join '-', @parts[ $i + 1 .. $#parts ];
            }
            return;
        }
    }

    # Fallback: maybe it's just <os> or <arch> alone
    $self->{os}   = $self->_match_os($t) // $self->{os};
    $self->{arch} = $ARCH_MAP{$t}        // $self->{arch};
}

sub _match_os ( $self, $str ) {
    for my $key (@OS_PATTERNS) {
        return $OS_MAP{$key} if $str =~ /^$key/i;
    }
    return undef;
}
1;
