package Brocken::Compiler::DataSegment {
    use v5.40;
    use utf8;
    use feature 'class';
    no warnings 'experimental::class', 'portable';
    use Encode qw(encode);

    class Brocken::Compiler::DataSegment {
        field $raw_data : reader : writer = '';
        field %string_offsets;

        method add_string($str) {
            $str //= '';
            return $string_offsets{$str} if exists $string_offsets{$str};
            my $utf8_bytes = encode( 'UTF-8', $str );
            my $byte_len   = length($utf8_bytes);

            # HEADER: Byte Length + 24 | Cycle 0 | Flags (Leaf/String=Bits 63-62)
            my $total_sz = $byte_len + 24;
            my $header   = $total_sz | hex("C000000000000000");    # Leaf bits set
            my $offset   = length($raw_data);
            $raw_data .= pack( 'Q<',    $header );
            $raw_data .= pack( 'Q< Q<', $byte_len, length($str) );
            $raw_data .= $utf8_bytes . "\0";                       # Force a null byte for C-FFI compatibility

            # Padding to 8-byte alignment
            my $pad = ( 8 - ( length($raw_data) % 8 ) ) % 8;
            $raw_data .= "\0" x $pad;
            return $string_offsets{$str} = $offset + 8;
        }

        method add_raw_bytes($bytes) {
            my $offset = length($raw_data);
            $raw_data .= $bytes;
            my $pad = ( 8 - ( length($raw_data) % 8 ) ) % 8;
            $raw_data .= "\0" x $pad;
            return $offset;
        }
    }
}
1;
__END__

=pod

=head1 NAME

Brocken::Compiler::DataSegment - String constant storage with GC headers

=head1 SYNOPSIS

    my $ds = Brocken::Compiler::DataSegment->new();
    my $offset = $ds->add_string("Hello, World!");
    my $raw = $ds->raw_data();

=head1 DESCRIPTION

Holds all Brocken string constants and raw data in a flat byte buffer. Each string is preceded by a GC-compatible
header:

  [8 bytes GC header (Leaf bit | Byte Length)]
  [8 bytes byte_len]
  [8 bytes char_len]
  [data...]

=head1 METHODS

=head2 add_raw_bytes($bytes)

Adds raw bytes to the segment and returns the offset. Padded to 8-byte alignment.

=head2 add_string($string)

Enrolls a Perl string as a UTF-8 encoded constant with GC headers. Returns the byte offset (skipping the GC header,
pointing to metadata).

=head2 raw_data

Returns the complete byte buffer for writing into the binary's .data section.

=cut
