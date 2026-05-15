package Brocken::Format::ELF {
    use v5.40;
    use feature 'class';
    no warnings 'experimental::class';
    #
    class Brocken::Format::ELF : isa(Brocken::Format) {

        method _setup_layout( $l, $t, $d, $a, $o, $dbg = 0 ) {
            $l->add_section( '.text', $t, 5 );    # RX
            $l->add_section( '.data', $d, 6 );    # RW
            if ( $dbg >= 1 ) {
                $l->add_section( '.debug_line',     4096, 0 );
                $l->add_section( '.debug_info',     4096, 0 );
                $l->add_section( '.debug_abbrev',   4096, 0 );
                $l->add_section( '.debug_frame',    4096, 0 );
                $l->add_section( '.debug_aranges',  4096, 0 );
                $l->add_section( '.debug_pubnames', 4096, 0 );
                $l->add_section( '.eh_frame',       4096, 0 );
            }
        }
        method image_base () { return 0x400000; }

        method write_bin( $f, $text, $data, $arch, $os ) {
            my $l    = $self->layout;
            my $base = $self->image_base;

            # 1. Build Section Names String Table (.shstrtab)
            my $shstrtab = "\0";
            my %sh_name_off;
            for my $s ( $l->sections ) {
                $sh_name_off{ $s->{name} } = length($shstrtab);
                $shstrtab .= $s->{name} . "\0";
            }
            $sh_name_off{'.shstrtab'} = length($shstrtab);
            $shstrtab .= ".shstrtab\0";
            $sh_name_off{'.note.GNU-stack'} = length($shstrtab);
            $shstrtab .= ".note.GNU-stack\0";

            # 2. Open file and write payloads based on layout
            open my $fh, '>', $f or die $!;
            binmode $fh;
            for my $s ( $l->sections ) {
                my $payload = $s->{name} eq '.text' ? $text :
                    ( $s->{name} =~ /^\.(debug|eh_frame)/ ? ( $self->debug_section( $s->{name} ) || "\0" ) : ( $data || "\0" ) );
                $payload .= ( "\0" x ( $s->{size} - length($payload) ) ) if length($payload) < $s->{size};
                seek( $fh, $s->{off}, 0 );
                print $fh $payload;
            }

            # 3. Write Section Header String Table and Section Headers at the end
            my $shstrtab_off = tell($fh);
            print $fh $shstrtab;
            my $shoff   = tell($fh);
            my @shdrs   = ();
            my $sh_ents = 64;

            # NULL Section (index 0)
            push @shdrs, pack( 'L L Q Q Q Q L L Q Q', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 );

            # Real sections from layout
            for my $s ( $l->sections ) {
                my $type  = 1;    # SHT_PROGBITS
                my $flags = 0;
                if ( $s->{name} eq '.text' ) {
                    $flags = 6;    # SHF_ALLOC | SHF_EXECINSTR
                }
                elsif ( $s->{name} eq '.data' ) {
                    $flags = 3;    # SHF_ALLOC | SHF_WRITE
                }
                elsif ( $s->{name} =~ /^\.(debug|eh_frame)/ ) {
                    $flags = 0;    # Debug sections are not loaded
                }
                push @shdrs,
                    pack(
                    'L L Q Q Q Q L L Q Q',
                    $sh_name_off{ $s->{name} },
                    $type,     $flags, ( $flags & 2 ? $base + $s->{rva} : 0 ),
                    $s->{off}, $s->{size}, 0, 0, 1, 0
                    );
            }

            # .shstrtab section header
            my $shstrtab_idx = scalar(@shdrs);
            push @shdrs, pack( 'L L Q Q Q Q L L Q Q', $sh_name_off{'.shstrtab'}, 3, 0, 0, $shstrtab_off, length($shstrtab), 0, 0, 1, 0 );

            # .note.GNU-stack section header (empty, but signals non-exec stack)
            push @shdrs, pack( 'L L Q Q Q Q L L Q Q', $sh_name_off{'.note.GNU-stack'}, 1, 0, 0, 0, 0, 0, 0, 1, 0 );

            # Write all section headers
            seek( $fh, $shoff, 0 );
            print $fh $_ for @shdrs;

            # 4. Finalize ELF Header and Program Headers at offset 0
            my $ehdr = pack(
                'A4 C C C C C x7 S S L Q Q Q L S S S S S S',
                "\x7fELF", 2, 1, 1, 0, 0, $elf_type, ( $arch eq 'arm64' ? 183 : 62 ),
                1,         $base + $l->get('.text')->{rva},
                64,        $shoff, 0, 64, 56, 2, 64, scalar(@shdrs), $shstrtab_idx
            );
            my $ph_t = pack(
                'LL Q Q Q Q Q Q',         1, 5,    # PT_LOAD, RX
                $l->get('.text')->{off},  $base + $l->get('.text')->{rva}, $base + $l->get('.text')->{rva}, $l->get('.text')->{size},
                $l->get('.text')->{size}, 0x1000
            );
            my $ph_d = pack(
                'LL Q Q Q Q Q Q',         1, 6,    # PT_LOAD, RW
                $l->get('.data')->{off},  $base + $l->get('.data')->{rva}, $base + $l->get('.data')->{rva}, $l->get('.data')->{size},
                $l->get('.data')->{size}, 0x1000
            );
            seek( $fh, 0, 0 );
            print $fh $ehdr, $ph_t, $ph_d;
            close $fh;
            chmod 0755, $f;
            return $f;
        }
    }
}
1;
__END__

=pod

=head1 NAME

Brocken::Format::ELF - Linux ELF64 binary format writer

=head1 DESCRIPTION

Builds a Linux ELF64 executable. Emits ELF header (EM_X86_64 or EM_AARCH64), two PT_LOAD program headers (.text RX,
.data RW), and appends code and data at the computed offsets.

=head1 METHODS

=head2 write_bin($filename, $text, $data, $arch, $os)

Writes the complete ELF executable to disk.

=cut
}
1;
 $text, $data, $arch, $os)

Writes the complete ELF executable to disk.

=cut
}
1;
