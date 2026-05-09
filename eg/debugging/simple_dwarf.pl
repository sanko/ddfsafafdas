use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';
use lib 'lib';
use Brocken::Format::DWARF;

# Build fake source locations
my @source_locs = (
    { offset => 0x0000, line => 1,  col => 1 },
    { offset => 0x0040, line => 5,  col => 8 },
    { offset => 0x0080, line => 10, col => 4 },
    { offset => 0x00C0, line => 15, col => 12 },
);

# Build fake function ranges (win64 style: 8 preserved regs, ctx=64)
my @func_ranges = (
    { name => 'main', start => 0x0000, end => 0x00F0, ctx_size => 64, params => [], locals => [] },
    {   name     => 'helper',
        start    => 0x0100,
        end      => 0x01A0,
        ctx_size => 64,
        params   => [ { name => '$x', type => 'Int', slot => 16 }, ],
        locals   => [ { name => '$y', type => 'Int', slot => 24 }, ]
    },
    { name => 'anon_fn', start => 0x0200, end => 0x0250, ctx_size => 64, params => [], locals => [] },
);
my $TEXT_BASE = 0x140001000;                   # image_base + .text RVA
my $EH_BASE   = 0x140005000;                   # image_base + .eh_frame RVA (PE, but we demonstrate it)
my $dw        = Brocken::Format::DWARF->new(
    source_locs   => \@source_locs,
    text_base     => $TEXT_BASE,
    eh_frame_base => $EH_BASE,
    func_ranges   => \@func_ranges,
    context_size  => 64,
);
my $sections = $dw->build_all;
printf "%-20s  %s\n", 'Section', 'Size (bytes)';
printf "%-20s  %s\n", '-------', '-----------';

for my $name ( sort keys %$sections ) {
    printf "%-20s  %d\n", $name, length( $sections->{$name} );
}
say "\n--- .debug_frame hex dump (first 64 bytes) ---";
my $frame = $sections->{'.debug_frame'};
for ( my $i = 0; $i < length($frame) && $i < 64; $i += 16 ) {
    my $chunk = substr( $frame, $i, 16 );
    printf "%04X: %s  %s\n", $i, join( ' ', map { sprintf( '%02X', ord($_) ) } split( '', $chunk ) ), ( length($chunk) < 16 ? '' : '' );
}
say "\n--- .eh_frame hex dump (first 64 bytes) ---";
my $eh = $sections->{'.eh_frame'};
for ( my $i = 0; $i < length($eh) && $i < 64; $i += 16 ) {
    my $chunk = substr( $eh, $i, 16 );
    printf "%04X: %s  %s\n", $i, join( ' ', map { sprintf( '%02X', ord($_) ) } split( '', $chunk ) ), ( length($chunk) < 16 ? '' : '' );
}
say "\nDone. Total DWARF data: " . ( length( join( '', values %$sections ) ) ) . " bytes";
