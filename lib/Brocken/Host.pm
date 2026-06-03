package Brocken::Host;
use v5.40;
use strict;
use warnings;
our %OS_MAP = (
    MSWin32     => 'win64',
    darwin      => 'macos',
    freebsd     => 'freebsd',
    netbsd      => 'netbsd',
    openbsd     => 'openbsd',
    dragonfly   => 'dragonfly',
    solaris     => 'solaris',
    illumos     => 'solaris',
    sunos       => 'solaris',
    haiku       => 'haiku',
    midnightbsd => 'midnightbsd',
    linux       => 'linux',
    gnukfreebsd => 'freebsd',
    cygwin      => 'win64',
    msys        => 'win64',
);

sub os {
    return $OS_MAP{$^O} // 'linux';
}

sub arch {
    return $ENV{BROCKEN_ARCH} if $ENV{BROCKEN_ARCH};
    if ( $^O eq 'MSWin32' || $^O eq 'cygwin' || $^O eq 'msys' ) {
        my $pa   = $ENV{PROCESSOR_ARCHITECTURE}      // '';
        my $paW  = $ENV{PROCESSOR_ARCHITECTUREW6432} // '';
        my $comb = "$pa $paW";
        return 'arm64' if $comb =~ /ARM64/i;
        return 'arm64' if $paW =~ /ARM64/i;
        if ( $pa eq 'AMD64' || $pa eq 'x86' ) {
            my $id = `reg query "HKLM\\HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0" /v "Identifier" 2>NUL`;
            return 'arm64' if defined $id && $id =~ /ARM/i;
        }
        return 'x64'   if $comb =~ /AMD64|x86_64/i;
        return 'x64'   if $comb =~ /x86/i;
        return 'x64'   if $comb =~ /i\d86/i;
        return 'arm';
    }
    my $m = `uname -m`;
    $m //= '';
    chomp $m;
    return 'riscv64' if $m =~ /riscv64/i;
    return 'arm64'   if $m =~ /aarch64|arm64|armv8/i;
    return 'x64'     if $m =~ /x86_64|amd64/i;
    return 'x64'     if $m =~ /i\d86|x86/i;
    return 'arm'     if $m =~ /^arm/i;
    return 'x64';
}
sub is_windows { os() eq 'win64' }
sub is_unix    { os() ne 'win64' }
sub is_x64     { arch() eq 'x64' }
sub is_arm     { arch() =~ /^arm/i }
sub is_riscv   { arch() =~ /riscv/i }
1;
