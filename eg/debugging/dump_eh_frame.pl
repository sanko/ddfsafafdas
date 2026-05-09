use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';
use lib 'lib';
use constant { IMAGE_BASE => 0x400000, TEXT_RVA => 0x1000 };
my $file = shift // 'brocken_out';
open my $fh, '<:raw', $file or die "Cannot open $file: $!";
my $data = do { local $/; <$fh> };
close $fh;

if ( substr( $data, 0, 4 ) eq "\x7fELF" ) {
    say "ELF binary detected";
    my $shoff         = unpack( 'x40 Q<', $data );
    my $shent         = unpack( 'x58 S<', $data );
    my $shnum         = unpack( 'x60 S<', $data );
    my $shstrndx      = unpack( 'x62 S<', $data );
    my $shstrtab_off  = $shoff + $shstrndx * $shent;
    my $shstrtab      = unpack( "x${shstrtab_off} x24 Q<", pack( 'x', 0 ) ) . '';    # simplified
    my $shstrtab_size = unpack( "x${shstrtab_off} x20 Q<", $data );
    my $shstr         = substr( $data, unpack( "x${shstrtab_off} x24 Q<", $data ), $shstrtab_size );

    for my $i ( 0 .. $shnum - 1 ) {
        my $secoff   = $shoff + $i * $shent;
        my $name_off = unpack( "x${secoff} L<", $data );
        my $name     = substr( $shstr, $name_off );
        $name =~ s/\0.*//;
        next unless $name eq '.eh_frame';
        my $sec_size     = unpack( "x${secoff} x20 Q<", $data );
        my $sec_data_off = unpack( "x${secoff} x24 Q<", $data );
        my $sec_addr     = unpack( "x${secoff} x16 Q<", $data );
        my $eh_frame     = substr( $data, $sec_data_off, $sec_size );
        dump_eh_frame( $eh_frame, $sec_addr );
        last;
    }
}
elsif ( substr( $data, 0, 2 ) eq "MZ" ) {
    say "PE binary detected (checking for .eh_frame)";
    my $pe_off       = unpack( 'x60 L<',            $data );
    my $num_sections = unpack( "x${pe_off} x2 S<",  $data );
    my $opt_hdr_size = unpack( "x${pe_off} x16 S<", $data );
    my $sec_start    = $pe_off + 20 + $opt_hdr_size;
    for my $i ( 0 .. $num_sections - 1 ) {
        my $off   = $sec_start + $i * 40;
        my $sname = substr( $data, $off, 8 );
        $sname =~ s/\0.*//;
        next unless $sname eq '.eh_frame';
        my $sec_size = unpack( "x${off} x8 L<",  $data );
        my $sec_rva  = unpack( "x${off} x12 L<", $data );
        my $sec_raw  = unpack( "x${off} x16 L<", $data );
        my $eh_frame = substr( $data, $sec_raw, $sec_size );
        dump_eh_frame( $eh_frame, IMAGE_BASE + $sec_rva );
        last;
    }
}
else {
    die "Unknown binary format";
}

sub dump_eh_frame {
    my ( $data, $section_addr ) = @_;
    say "\n.eh_frame section at 0x" . sprintf( '%X', $section_addr );
    say "Total size: " . length($data) . " bytes\n";
    my $pos = 0;
    my $cie_offset;

    # CIE
    my ($cie_len) = unpack( "x${pos} L<", $data );
    $cie_offset = $pos;
    say "--- CIE at offset $pos (length $cie_len) ---";
    my ($cie_id) = unpack( "x${pos} x4 L<", $data );
    die "Not a CIE (id=0x" . sprintf( '%X', $cie_id ) . ")" unless $cie_id == 0;
    my ($version) = unpack( "x${pos} x8 C", $data );
    say "  Version: $version";
    my $aug_start = $pos + 9;
    my $aug       = '';

    for my $i ( $aug_start .. $aug_start + 10 ) {
        last if ord( substr( $data, $i, 1 ) ) == 0;
        $aug .= substr( $data, $i, 1 );
    }
    say "  Augmentation: '$aug'";
    $pos += 4 + $cie_len;

    # FDEs
    my $count = 0;
    while ( $pos < length($data) ) {
        my ($fde_len) = unpack( "x${pos} L<", $data );
        last if $fde_len == 0;
        $count++;
        my ($cie_ptr) = unpack( "x${pos} x4 L<",  $data );
        my ($loc)     = unpack( "x${pos} x8 l<",  $data );
        my ($range)   = unpack( "x${pos} x12 L<", $data );
        my $func_addr = $section_addr + $pos + 8 + $loc;
        say "  FDE $count: len=$fde_len cie_ptr=" . sprintf( '0x%X', $cie_ptr ) . " func=0x" . sprintf( '%X', $func_addr ) . " range=$range";
        $pos += 4 + $fde_len;
    }
    say "\nTotal: $count FDE(s)";
}
