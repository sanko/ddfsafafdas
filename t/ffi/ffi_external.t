use v5.40;
use utf8;
use Test2::V0;
use lib 'lib';
subtest 'Win32::API VirtualAlloc lifecycle' => sub {
    eval { require Win32::API; 1 } or skip_all "Win32::API not available";
    my $VirtualAlloc = Win32::API->new( 'kernel32.dll', 'VirtualAlloc', 'QQNN', 'Q' );
    ok $VirtualAlloc, 'VirtualAlloc bound';
    return unless $VirtualAlloc;
    my $ptr = $VirtualAlloc->Call( 0, 4096, 0x3000, 0x40 );
    ok $ptr, 'VirtualAlloc returned non-zero pointer';
    return unless $ptr;
    my $RtlMoveMemory = Win32::API->new( 'kernel32.dll', 'RtlMoveMemory', 'QQQ', 'V' );
    ok $RtlMoveMemory, 'RtlMoveMemory bound';
    my $data    = "Hello from Win32::API!";
    my $src_ptr = unpack( 'Q', pack( 'p', $data ) );
    $RtlMoveMemory->Call( $ptr, $src_ptr, length($data) );
    my $read_back = unpack( 'p', pack( 'Q', $ptr ) );
    is $read_back, 'Hello from Win32::API!', 'memory write/read verified';
    my $VirtualFree = Win32::API->new( 'kernel32.dll', 'VirtualFree', 'QQN', 'N' );
    ok $VirtualFree, 'VirtualFree bound';
    $VirtualFree->Call( $ptr, 0, 0x8000 );
    pass 'memory freed';
};
subtest 'Affix symbol resolution' => sub {
    $^O eq 'MSWin32'                                                               or skip_all 'Windows-only test';
    eval { require Affix; Affix->import(qw(load_library find_symbol address)); 1 } or skip_all "Affix not available";
    my $lib = load_library('kernel32.dll');
    ok $lib, 'kernel32 library loaded';
    my $proc = find_symbol( $lib, 'VirtualAlloc' );
    ok $proc, 'VirtualAlloc symbol found';
    my $addr = address($proc);
    ok $addr, 'VirtualAlloc address resolved';
};
subtest 'Win32::API VirtualAlloc with vec write' => sub {
    $^O eq 'MSWin32' or skip_all 'Windows-only test';
    eval { require Win32::API; Win32::API->Import( 'kernel32.dll', 'VirtualAlloc', [ 'P', 'N', 'N', 'N' ], 'L' ); 1 } or
        skip_all "Win32::API not available";
    my $ptr = VirtualAlloc( 0, 4096, 0x3000, 0x40 );
    ok $ptr, 'VirtualAlloc succeeded' or return;
    my $src = "\x90" x 100;
    for my $i ( 0 .. length($src) - 1 ) {
        vec( $ptr, $i, 8 ) = ord( substr( $src, $i, 1 ) );
    }
    pass 'vec write completed';
};
done_testing;

