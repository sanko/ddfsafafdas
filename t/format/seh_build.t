use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
require Brocken::Target::Format::PE;
require Brocken::Target::Format::Layout;
use Brocken::TestHelpers qw(make_fake_funcs);
my $TEXT_RVA  = 0x1000;
my $XDATA_RVA = 0x5000;
subtest 'build_xdata' => sub {
    my $pe = Brocken::Target::Format::PE->new;
    $pe->set_preserved_regs( [qw(rbp rbx rdi rsi r12 r13 r14 r15)] );
    my $xdata = $pe->_build_xdata;
    ok length($xdata) > 0, 'xdata has content';
    is length($xdata), 28, 'xdata is 28 bytes';
    my ($version_flags_prolog) = unpack( 'v', $xdata );
    my $version                = $version_flags_prolog & 0x07;
    my $flags                  = ( $version_flags_prolog >> 3 ) & 0x1F;
    my $prolog                 = ( $version_flags_prolog >> 6 ) & 0xFF;
    is $version, 1, 'UNWIND_INFO version 1';
    is $flags,   0, 'No exception handler flags';
    is( ( $version_flags_prolog >> 8 ) & 0xFF, 22, 'SizeOfProlog = 22' );
    my ($count_of_codes) = unpack( 'x2 C', $xdata );
    is $count_of_codes, 11, 'CountOfCodes = 11';
    my ($frame_reg) = unpack( 'x3 C', $xdata );
    is $frame_reg, 5, 'FrameRegister = 5 (RBP)';
    my $codes          = substr( $xdata, 4 );
    my @expected_codes = (
        [ 22, 0x01 ],    # UWOP_ALLOC_LARGE at end of sub rsp
        [ 4,  0x02 ],    # scaled size = 516 (0x0204)
        [ 15, 0x03 ],    # UWOP_SET_FPREG at end of mov rbp,rsp
        [ 12, 0xF0 ],    # UWOP_PUSH_NONVOL r15
        [ 10, 0xE0 ],    # UWOP_PUSH_NONVOL r14
        [ 8,  0xD0 ],    # UWOP_PUSH_NONVOL r13
        [ 6,  0xC0 ],    # UWOP_PUSH_NONVOL r12
        [ 4,  0x60 ],    # UWOP_PUSH_NONVOL rsi
        [ 3,  0x70 ],    # UWOP_PUSH_NONVOL rdi
        [ 2,  0x30 ],    # UWOP_PUSH_NONVOL rbx
        [ 1,  0x50 ],    # UWOP_PUSH_NONVOL rbp
        [ 0,  0x00 ],    # padding
    );
    for my $i ( 0 .. $#expected_codes ) {
        my ( $co, $info ) = unpack( "x" . ( $i * 2 ) . "CC", $codes );
        is $co,   $expected_codes[$i][0], "unwind code $i code offset";
        is $info, $expected_codes[$i][1], "unwind code $i info";
    }
};
subtest 'build_pdata' => sub {
    my $funcs = make_fake_funcs;
    my $pe    = Brocken::Target::Format::PE->new;
    $pe->set_func_ranges($funcs);
    my $pdata = $pe->_build_pdata( $TEXT_RVA, $XDATA_RVA );
    ok length($pdata) > 0, 'pdata has content';
    is length($pdata), scalar(@$funcs) * 12, 'pdata is 12 bytes per function';
    for my $i ( 0 .. $#$funcs ) {
        my $entry = substr( $pdata, $i * 12, 12 );
        my ( $begin, $end, $unwind ) = unpack( 'L< L< L<', $entry );
        is $begin,  $TEXT_RVA + $funcs->[$i]{start}, "FDE $i BeginAddress";
        is $end,    $TEXT_RVA + $funcs->[$i]{end},   "FDE $i EndAddress";
        is $unwind, $XDATA_RVA,                      "FDE $i UnwindData (shared)";
    }
};
subtest 'full pipeline with layout' => sub {
    my $funcs = make_fake_funcs;
    my $pe    = Brocken::Target::Format::PE->new;
    $pe->set_func_ranges($funcs);
    $pe->set_preserved_regs( [qw(rbp rbx rdi rsi r12 r13 r14 r15)] );
    my $l = Brocken::Target::Format::Layout->new( file_align => 0x200, section_align => 0x1000 );
    $l->add_section( '.text',  4096, 0x60000020 );
    $l->add_section( '.data',  4096, 0xC0000040 );
    $l->add_section( '.pdata', 4096, 0x42000040 );
    $l->add_section( '.xdata', 4096, 0x42000040 );
    $l->calculate(0x1000);
    my $xdata_data = $pe->_build_xdata;
    my $pdata_data = $pe->_build_pdata( $l->get('.text')->{rva}, $l->get('.xdata')->{rva} );
    $l->get('.xdata')->{size} = length($xdata_data);
    $l->get('.pdata')->{size} = length($pdata_data);
    $l->calculate(0x1000);
    is $l->get('.xdata')->{size}, 28,                   '.xdata section size = 28';
    is $l->get('.pdata')->{size}, scalar(@$funcs) * 12, '.pdata section size = 12 * N';
};
done_testing;
