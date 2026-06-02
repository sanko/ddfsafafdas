package Brocken::Format::Layout {
    use v5.40;
    use feature 'class';
    no warnings 'experimental::class';

    class Brocken::Format::Layout {
        field $file_align    : param : reader;
        field $section_align : param : reader;
        field @sections;
        field $header_size : reader = 0;

        method add_section( $name, $size, $flags ) {
            warn "Layout: Adding section $name (size: $size)\n" if $ENV{BROCKEN_JIT_DEBUG};
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
        method sections() {@sections}
    }
}
1;
__END__

=pod

=head1 NAME

Brocken::Format::Layout - Section layout calculator for binary files

=head1 SYNOPSIS

  my $layout = Brocken::Format::Layout->new(
      file_align    => 0x200,
      section_align => 0x1000
  );
  $layout->add_section('.text', length($code), 0x60000020);
  $layout->calculate(0x400);

=head1 DESCRIPTION

Calculates file offsets and Relative Virtual Addresses (RVAs) for binary sections, ensuring they are correctly aligned
according to platform requirements.

=head1 FIELDS

=over

=item file_align

Alignment of sections within the physical file (e.g., 0x200 for PE).

=item section_align

Alignment of sections when loaded into memory (e.g., 0x1000 for PE).

=item header_size

The calculated size of the file headers, rounded up to C<file_align>.

=back

=head1 METHODS

=head2 add_section($name, $size, $flags)

Registers a new section. C<$flags> are format-specific (e.g., PE characteristics).

=head2 calculate($min_hdr)

Computes offsets and RVAs for all registered sections. C<$min_hdr> is the minimum required space for headers. Returns
the total virtual size of the image.

=head2 get($name)

Returns the metadata hashref for the named section.

=head2 sections()

Returns a list of all section metadata hashrefs.

=cut
