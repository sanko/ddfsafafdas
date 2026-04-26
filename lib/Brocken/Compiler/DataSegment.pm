package Brocken::Compiler::DataSegment {
    use v5.40;
    use utf8;
    use feature 'class';
    no warnings 'portable', 'experimental::class';
    use Encode qw(encode);

    class Brocken::Compiler::DataSegment {
        field $raw_data = '';
        field %string_offsets;

        method add_string($str) {
            return $string_offsets{$str} if exists $string_offsets{$str};
            my $offset     = length($raw_data);
            my $utf8_bytes = encode( 'UTF-8', $str );
            my $byte_len   = length($utf8_bytes);
            $raw_data .= pack( 'Q< Q< Q<', $byte_len, length($str), ( $str =~ /^[\x00-\x7f]*$/ ? 1 : 0 ) );
            $raw_data .= $utf8_bytes;
            $raw_data .= "\0" x ( ( 8 - ( ( 24 + $byte_len ) % 8 ) ) % 8 );
            return $string_offsets{$str} = $offset;
        }
        method get_raw_data() { return $raw_data; }
    }
}
1;
