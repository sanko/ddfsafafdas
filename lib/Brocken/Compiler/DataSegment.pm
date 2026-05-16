package Brocken::Compiler::DataSegment {
    use v5.40;
    use utf8;
    use feature 'class';
    no warnings 'experimental::class', 'portable';
    use Encode qw(encode);

    class Brocken::Compiler::DataSegment {
        field $raw_data = '';
        field %string_offsets;

        method add_raw_bytes($bytes) {
            my $offset = length($raw_data);
            $raw_data .= $bytes;

            # Padding to 8-byte alignment
            my $pad = ( 8 - ( length($raw_data) % 8 ) ) % 8;
            $raw_data .= "\0" x $pad;
            return $offset;
        }

        method add_string($str) {
            return $string_offsets{$str} if exists $string_offsets{$str};
            my $offset     = length($raw_data);
            my $utf8_bytes = encode( 'UTF-8', $str );
            my $byte_len   = length($utf8_bytes);

            # HEADER: Bit 61 (Leaf) | Byte Length
            # This tells the GC "I am live, but I contain no pointers"
            my $header = $byte_len | 0x2000000000000000;
            $raw_data .= pack( 'Q<',    $header );
            $raw_data .= pack( 'Q< Q<', $byte_len, length($str) );    # Metadata
            $raw_data .= $utf8_bytes;

            # Padding to 8-byte alignment
            my $pad = ( 8 - ( length($raw_data) % 8 ) ) % 8;
            $raw_data .= "\0" x $pad;

            # Return pointer to the Metadata (skip the 8-byte GC header)
            return $string_offsets{$str} = $offset + 8;
        }
        method get_raw_data() { return $raw_data; }
    }
}
1;
__END__

=pod

=head1 NAME

Brocken::Compiler::DataSegment - String constant storage with GC headers

=head1 DESCRIPTION

Holds all Brocken string constants in a flat byte buffer. Each string is preceded by a GC-compatible header:

  [1 byte flags][4 bytes byte_len][4 bytes char_len][data...]

Bit 0 of flags is the leaf bit (1 = no pointers inside).

=head1 METHODS

=head2 add_string($string)

Enrolls a Perl string as a UTF-8 encoded constant. Returns the byte offset into the data segment (suitable for
C<load_data_addr> IR instructions).

=head2 get_raw_data

Returns the complete byte buffer for writing into the binary's .data section.

=cut

