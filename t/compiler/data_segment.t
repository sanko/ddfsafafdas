use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
use Brocken::Compiler::DataSegment;
subtest 'add_string returns offset' => sub {
    my $ds  = Brocken::Compiler::DataSegment->new;
    my $off = $ds->add_string("hello");
    ok defined($off), 'offset defined';
    ok $off >= 0,     'offset non-negative';
};
subtest 'add_string deduplication' => sub {
    my $ds   = Brocken::Compiler::DataSegment->new;
    my $off1 = $ds->add_string("dedupe_test");
    my $off2 = $ds->add_string("dedupe_test");
    is $off1, $off2, 'duplicate strings return same offset';
};
subtest 'add_string different strings get different offsets' => sub {
    my $ds   = Brocken::Compiler::DataSegment->new;
    my $off1 = $ds->add_string("string_a");
    my $off2 = $ds->add_string("string_b");
    ok $off1 != $off2, 'different strings get different offsets';
};
subtest 'raw_data has content after add_string' => sub {
    my $ds = Brocken::Compiler::DataSegment->new;
    $ds->add_string("data_test");
    my $raw = $ds->raw_data;
    ok length($raw) > 24, 'raw data has header + content';
};
subtest 'raw_data is 8-byte aligned' => sub {
    my $ds = Brocken::Compiler::DataSegment->new;
    $ds->add_string("a");
    my $raw = $ds->raw_data;
    is length($raw) % 8, 0, 'raw data length is 8-byte aligned';
};
subtest 'add_raw_bytes basic' => sub {
    my $ds  = Brocken::Compiler::DataSegment->new;
    my $off = $ds->add_raw_bytes("\x41\x42\x43\x44");
    ok defined($off), 'raw bytes offset';
    is $off, 0, 'first raw bytes at offset 0';
};
subtest 'add_raw_bytes alignment' => sub {
    my $ds = Brocken::Compiler::DataSegment->new;
    $ds->add_raw_bytes("ABCD");
    my $raw = $ds->raw_data;
    is length($raw) % 8, 0, 'raw data aligned after add_raw_bytes';
};
subtest 'mixed add_string and add_raw_bytes' => sub {
    my $ds    = Brocken::Compiler::DataSegment->new;
    my $s_off = $ds->add_string("mixed_test");
    my $r_off = $ds->add_raw_bytes("\x01\x02");
    my $raw   = $ds->raw_data;
    ok length($raw) > 30,                  'mixed content has data';
    ok $s_off < $r_off || $s_off > $r_off, 'offsets are different';
};
subtest 'GC header format' => sub {
    my $ds = Brocken::Compiler::DataSegment->new;
    $ds->add_string("header_test");
    my $raw = $ds->raw_data;
    my ($header) = unpack( 'Q<', substr( $raw, 0, 8 ) );
    ok $header & hex("8000000000000000"), 'leaf bit (bit 63) set';
    ok $header & hex("4000000000000000"), 'string bit (bit 62) set';
};
done_testing;
