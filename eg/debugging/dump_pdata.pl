use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';
use constant IMAGE_BASE => 0x140000000;
my $file = shift // 'brocken_out.exe';
open my $fh, '<:raw', $file or die "Cannot open $file: $!";
my $data = do { local $/; <$fh> };
close $fh;
die "Not a PE file" unless substr( $data, 0, 2 ) eq "MZ";
my $pe_off       = unpack( 'x60 L<',            $data );
my $num_sections = unpack( "x${pe_off} x2 S<",  $data );
my $opt_hdr_size = unpack( "x${pe_off} x16 S<", $data );
my $sec_start    = $pe_off + 20 + $opt_hdr_size;

# Find .pdata and .xdata sections
my ( $pdata_off, $pdata_size, $pdata_rva );
my ( $xdata_off, $xdata_size, $xdata_rva );
for my $i ( 0 .. $num_sections - 1 ) {
    my $off   = $sec_start + $i * 40;
    my $sname = substr( $data, $off, 8 );
    $sname =~ s/\0.*//;
    my $vsz = unpack( "x${off} x8  L<", $data );
    my $rva = unpack( "x${off} x12 L<", $data );
    my $raw = unpack( "x${off} x16 L<", $data );
    my $rsz = unpack( "x${off} x20 L<", $data );
    if ( $sname eq '.pdata' ) {
        ( $pdata_off, $pdata_size, $pdata_rva ) = ( $raw, $rsz, $rva );
    }
    elsif ( $sname eq '.xdata' ) {
        ( $xdata_off, $xdata_size, $xdata_rva ) = ( $raw, $rsz, $rva );
    }
}
if ( !$pdata_off ) {
    die "No .pdata section found. Build with --debug=2 on win64.";
}
say "=== .pdata (Runtime Function Table) ===";
say "RVA: 0x" . sprintf( '%X', $pdata_rva ) . "  Size: $pdata_size bytes";
my $pdata_bytes = substr( $data, $pdata_off, $pdata_size );
my $num_entries = int( $pdata_size / 12 );
say "Entries: $num_entries\n";
printf "%-4s  %-18s  %-18s  %-18s\n", '#',  'BeginAddress', 'EndAddress', 'UnwindData';
printf "%-4s  %-18s  %-18s  %-18s\n", '--', '------------', '----------', '----------';

for my $i ( 0 .. $num_entries - 1 ) {
    my $entry = substr( $pdata_bytes, $i * 12, 12 );
    my ( $begin, $end, $unwind ) = unpack( 'L< L< L<', $entry );
    printf "%-4d  RVA=0x%08X  RVA=0x%08X  RVA=0x%08X\n", $i, $begin, $end, $unwind;
}
say "\n=== .xdata (Unwind Info) ===";
say "RVA: 0x" . sprintf( '%X', $xdata_rva ) . "  Size: $xdata_size bytes";
my $xdata_bytes        = substr( $data, $xdata_off, $xdata_size );
my ($ver_flags_prolog) = unpack( 'v', $xdata_bytes );
my $ver                = $ver_flags_prolog & 0x07;
my $flags              = ( $ver_flags_prolog >> 3 ) & 0x1F;
my $plen               = ( $ver_flags_prolog >> 6 ) & 0xFF;
my $codes              = unpack( 'x2 C', $xdata_bytes );
my $frame              = unpack( 'x3 C', $xdata_bytes );
say "  Version:           $ver";
say "  Flags:             0x" . sprintf( '%X', $flags );
say "  SizeOfProlog:      $plen bytes";
say "  CountOfCodes:      $codes";
printf "  FrameRegister:     0x%02X (Offset: %d)\n", $frame & 0x0F, ( $frame >> 4 ) & 0x0F;
my %UWOP = (
    0x00 => 'UWOP_PUSH_NONVOL',
    0x01 => 'UWOP_ALLOC_LARGE',
    0x02 => 'UWOP_ALLOC_SMALL',
    0x03 => 'UWOP_SET_FPREG',
    0x04 => 'UWOP_SAVE_NONVOL',
    0x05 => 'UWOP_SAVE_NONVOL_FAR',
    0x06 => 'UWOP_SAVE_XMM128',
    0x07 => 'UWOP_SAVE_XMM128_FAR',
    0x08 => 'UWOP_PUSH_MACHFRAME',
);
my %REG = map { $_ => 'r' . $_ } 0 .. 15;
$REG{$_} = $REG{$_} for 0 .. 15;
say "\n  Unwind codes:";
my $codes_data = substr( $xdata_bytes, 4 );

for my $i ( 0 .. $codes - 1 ) {
    my ( $co, $info ) = unpack( "x" . ( $i * 2 ) . "CC", $codes_data );
    my $op   = $UWOP{ $info & 0x0F } // sprintf( 'UNKNOWN(0x%X)', $info & 0x0F );
    my $reg  = ( $info >> 4 ) & 0x0F;
    my $desc = "$op";
    if ( ( $info & 0x0F ) == 0x00 ) {
        $desc .= " $REG{$reg}";
    }
    elsif ( ( $info & 0x0F ) == 0x01 ) {
        $desc .= " scaled=" . unpack( "x" . ( ( $i + 1 ) * 2 ) . "S<", $codes_data );
    }
    printf "    [%2d] CodeOffset=%-2d  %s\n", $i, $co, $desc;
}

# Check all .pdata entries point to the same UNWIND_INFO
my $first_unwind = unpack( 'L<', substr( $pdata_bytes, 8, 4 ) );
my $all_same     = 1;
for my $i ( 1 .. $num_entries - 1 ) {
    my $uw = unpack( "x" . ( $i * 12 + 8 ) . "L<", $pdata_bytes );
    $all_same = 0 if $uw != $first_unwind;
}
say "\n  Shared UNWIND_INFO: " . ( $all_same ? "Yes (all entries)" : "No" );
