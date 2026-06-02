use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
require Brocken::Target::Format::PE;
require Brocken::Target::Format::Layout;
use Brocken::TestHelpers qw(make_fake_funcs);

# AMD64 SEH UNWIND_INFO layout:
#   16-bit LE: Version (3b) | Flags (5b) | SizeOfProlog (8b)
#   u8:  CountOfCodes
#   u8:  FrameRegister (4b) | FrameRegisterOffset (4b)
#   then CountOfCodes 16-bit code words, padded to a 4-byte boundary.
#
# We verify the xdata the compiler emits against the same prologue shape
# x64.pm actually produces for these preserved regs and frame size.

my $TEXT_RVA  = 0x1000;
my $XDATA_RVA = 0x5000;
my @WIN_REGS  = qw(rbp rbx rdi rsi r12 r13 r14 r15);

# Prologue shape (must mirror x64.pm's enter_func / push_frame):
#   1-byte push for regs 0-7, 2-byte push (REX prefix) for regs 8-15
#   then 3-byte mov rbp, rsp, then 7-byte sub rsp, imm32
my %SEH_REG = (
    rax => 0, rcx => 1, rdx => 2, rbx => 3, rsp => 4, rbp => 5, rsi => 6, rdi => 7,
    r8  => 8, r9  => 9, r10 => 10, r11 => 11, r12 => 12, r13 => 13, r14 => 14, r15 => 15
);

sub prologue_size_for (@regs) {
    my $n = 0;
    $n += ( $SEH_REG{$_} < 8 ) ? 1 : 2 for @regs;
    return $n + 3 + 7;    # pushes + mov rbp,rsp + sub rsp,imm32
}

sub push_offsets_for (@regs) {
    my @offs;
    my $o = 0;
    for my $r (@regs) {
        $o += ( $SEH_REG{$r} < 8 ) ? 1 : 2;
        push @offs, $o;
    }
    return @offs;
}

subtest 'build_xdata' => sub {
    my $pe = Brocken::Target::Format::PE->new;
    $pe->set_preserved_regs( \@WIN_REGS );
    $pe->set_frame_size(4128);
    my $xdata = $pe->_build_xdata;

    ok length($xdata) > 0, 'xdata has content';

    # --- Header ---
    my ($vfp) = unpack( 'v', $xdata );
    is $vfp & 0x07,                       1,  'UNWIND_INFO version 1';
    is( ( $vfp >> 3 ) & 0x1F,             0,  'No exception handler flags' );
    is( ( $vfp >> 8 ) & 0xFF,  prologue_size_for(@WIN_REGS), 'SizeOfProlog' );

    my ($count) = unpack( 'x2 C', $xdata );
    is $count, 11, 'CountOfCodes = 11 (1 alloc-as-2 + 1 SET_FPREG + 8 push)';

    my ($fr) = unpack( 'x3 C', $xdata );
    is $fr, ( $SEH_REG{rbp} << 4 ) | 0, 'FrameRegister = RBP (5), offset 0';

    # --- Unwind codes (in code-array order = reverse execution order) ---
    my $codes = substr( $xdata, 4 );

    # Code 0/1: UWOP_ALLOC_LARGE (op=1, OpInfo=2 for 2-byte scaled size)
    my $prologue_end = prologue_size_for(@WIN_REGS);
    is unpack( 'C',   $codes ), $prologue_end, 'ALLOC_LARGE: CodeOffset = end of prologue';
    is unpack( 'x1 C', $codes ), 0x21,         'ALLOC_LARGE: OpInfo=2, Op=1';
    is unpack( 'x2 S<', $codes ), 4128 / 8,    'ALLOC_LARGE: scaled size matches frame_size / 8';

    # Code 2: UWOP_SET_FPREG (op=3, OpInfo=offset) at the mov rbp, rsp
    my $push_offs      = [ push_offsets_for(@WIN_REGS) ];
    my $mov_rbp_offset = $push_offs->[-1] + 3;
    is unpack( 'x4 C', $codes ), $mov_rbp_offset, 'SET_FPREG: CodeOffset = after pushes + mov rbp,rsp';
    is unpack( 'x5 C', $codes ), ( 0 << 4 ) | 3,  'SET_FPREG: OpInfo=0, Op=3';

    # Codes 3-10: UWOP_PUSH_NONVOL (op=0, OpInfo=reg) in reverse order
    for my $i ( 0 .. $#WIN_REGS ) {
        my $reg = $WIN_REGS[ $#WIN_REGS - $i ];
        my $off = 6 + $i * 2;
        is unpack( "x$off C",        $codes ), $push_offs->[ $#WIN_REGS - $i ], "PUSH[$i] CodeOffset for $reg";
        is unpack( "x" . ( $off + 1 ) . " C", $codes ), ( $SEH_REG{$reg} << 4 ) | 0, "PUSH[$i] OpInfo=$SEH_REG{$reg} ($reg), Op=0";
    }

    # Padding to 4-byte alignment
    is length($codes) % 4, 0, 'codes section is DWORD-aligned';

    is length($xdata), 28, 'xdata is 28 bytes';
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
    $pe->set_preserved_regs( \@WIN_REGS );
    $pe->set_frame_size(4128);
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
    is $l->get('.xdata')->{size}, length($xdata_data), '.xdata section size matches _build_xdata length';
    is $l->get('.pdata')->{size}, scalar(@$funcs) * 12, '.pdata section size = 12 * N';
};
done_testing;
