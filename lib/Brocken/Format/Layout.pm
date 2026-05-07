package Brocken::Format::Layout {
    use v5.40;
    use feature 'class';
    no warnings 'experimental::class';

    class Brocken::Format::Layout {
        field $file_align    : param;
        field $section_align : param;
        field @sections;
        field $header_size = 0;

        method add_section( $name, $size, $flags ) {
            push @sections, { name => $name, size => ( $size || 1 ), flags => $flags, rva => 0, off => 0 };
        }

        method calculate($min_hdr) {
            $header_size = ( $min_hdr + $file_align - 1 ) & ~( $file_align - 1 );
            my $curr_off = $header_size;
            my $curr_rva = 0x1000;
            for my $s (@sections) {
                $s->{off} = $curr_off;
                $s->{rva} = $curr_rva;
                $curr_off += ( $s->{size} + $file_align - 1 ) & ~( $file_align - 1 );
                $curr_rva += ( $s->{size} + $section_align - 1 ) & ~( $section_align - 1 );
            }
            return $curr_rva;
        }

        method get($n) {
            for (@sections) { return $_ if $_->{name} eq $n }
            die "Layout Error: Section $n not found";
        }
        method sections()    {@sections}
        method header_size() {$header_size}
    }
}
1;
