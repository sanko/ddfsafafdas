use v5.40;
use feature 'class';
no warnings 'experimental::class';

class Brocken::Format::ELF : isa(Brocken::Format) {

    method _setup_layout( $l, $t, $d, $a, $o, $dbg = 0 ) {
        $l->add_section( '.text', $t, 5 );    # RX
        $l->add_section( '.data', $d, 6 );    # RW
        if ( $self->type eq 'shared' ) {
            $l->add_section( '.dynstr',  4096, 2 );
            $l->add_section( '.dynsym',  4096, 2 );
            $l->add_section( '.hash',    4096, 2 );
            $l->add_section( '.dynamic', 4096, 3 );
        }
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
    method image_base () { return $self->type eq 'shared' ? 0 : 0x400000; }

    method write_bin( $f, $text, $data, $arch, $os, $type = $self->type ) {
        my $l        = $self->layout;
        my $base     = $self->image_base;
        my $elf_type = $type eq 'shared' ? 3 : 2;    # ET_DYN or ET_EXEC

        # Comprehensive OSABI Map
        my %osabis = (
            linux     => 0,
            freebsd   => 9,
            netbsd    => 2,
            solaris   => 6,
            openbsd   => 0,    # OpenBSD prefers 0 + Note
            dragonfly => 0     # DragonFly prefers 0 + Note
        );
        my $osabi = $osabis{$os} // 0;

        # Generate Identification Notes for BSDs
        my $note_data     = '';
        my $pintable_data = '';
        if ( $os eq 'netbsd' ) {
            $note_data = pack( 'L<L<L<', 7, 4, 1 ) . "NetBSD\0\0" . pack( 'L<', 900000000 );
        }
        elsif ( $os eq 'freebsd' ) {
            $note_data = pack( 'L<L<L<', 8, 4, 1 ) . "FreeBSD\0" . pack( 'L<', 1400000 );
        }
        elsif ( $os eq 'dragonfly' ) {
            $note_data = pack( 'L<L<L<', 10, 4, 1 ) . "DragonFly\0\0" . pack( 'L<', 0 );
        }
        elsif ( $os eq 'openbsd' ) {
            $note_data = pack( 'L<L<L<', 8, 4, 1 ) . "OpenBSD\0" . pack( 'L<', 0 );
            my $pos      = 0;
            my $text_rva = $l->get('.text')->{rva};
            if ( $arch eq 'x64' ) {
                while ( ( my $idx = index( $text, "\x0F\x05", $pos ) ) != -1 ) {
                    my $vaddr = $base + $text_rva + $idx;
                    $pintable_data .= pack( 'L<L<', $vaddr, 1 );    # SYS_exit
                    $pintable_data .= pack( 'L<L<', $vaddr, 4 );    # SYS_write
                    $pos = $idx + 2;
                }
            }
            else {
                # ARM64 SVC #0
                while ( ( my $idx = index( $text, "\x01\x00\x00\xd4", $pos ) ) != -1 ) {
                    my $vaddr = $base + $text_rva + $idx;
                    $pintable_data .= pack( 'L<L<', $vaddr, 1 );
                    $pintable_data .= pack( 'L<L<', $vaddr, 4 );
                    $pos = $idx + 4;
                }
            }
        }

        # Exports & Dynamic Sections
        my ( $dynstr, $dynsym, $hash, $dynamic ) = ( '', '', '', '' );
        if ( $self->type eq 'shared' ) {
            my @exports = @{ $self->exported_funcs // [] };
            $dynstr = "\0";
            my %str_off;
            for my $name (@exports) {
                $str_off{$name} = length($dynstr);
                $dynstr .= $name . "\0";
            }
            my $dynstr_sz = length($dynstr);
            $dynsym = pack( 'L< C C S< Q< Q<', 0, 0, 0, 0, 0, 0 );    # Null symbol
            my $sym_idx = 1;
            for my $name (@exports) {
                my $rva = $l->get('.text')->{rva} + ( $self->labels->{"E_$name"} // 0 );
                $dynsym .= pack( 'L< C C S< Q< Q<', $str_off{$name}, 0x12, 0, 1, $base + $rva, 0 );
                $sym_idx++;
            }
            my $elf_hash = sub {
                my $name = shift;
                my $h    = 0;
                for my $c ( split //, $name ) {
                    $h = ( $h << 4 ) + ord($c);
                    $h &= 0xffffffff;    # Prevent 64-bit Perl promotion overflow
                    my $g = $h & 0xf0000000;
                    if ($g) { $h ^= ( $g >> 24 ); }
                    $h &= 0x0fffffff;    # Standard 32-bit clear
                }
                return $h;
            };
            my $nbucket = 3;
            my $nchain  = $sym_idx;
            my @buckets = (0) x $nbucket;
            my @chains  = (0) x $nchain;
            my $i       = 1;
            for my $name (@exports) {
                my $h = $elf_hash->($name);
                my $b = $h % $nbucket;
                $chains[$i]  = $buckets[$b];
                $buckets[$b] = $i;
                $i++;
            }
            $hash                      = pack( 'L<*', $nbucket, $nchain, @buckets, @chains );
            $l->get('.dynstr')->{size} = length($dynstr);
            $l->get('.dynsym')->{size} = length($dynsym);
            $l->get('.hash')->{size}   = length($hash);
            $l->calculate(0x1000);
            my $dyn_rva  = $l->get('.dynamic')->{rva};
            my $str_rva  = $l->get('.dynstr')->{rva};
            my $sym_rva  = $l->get('.dynsym')->{rva};
            my $hash_rva = $l->get('.hash')->{rva};
            $dynamic = '';
            $dynamic .= pack( 'Q< Q<', 4,  $base + $hash_rva );
            $dynamic .= pack( 'Q< Q<', 5,  $base + $str_rva );
            $dynamic .= pack( 'Q< Q<', 6,  $base + $sym_rva );
            $dynamic .= pack( 'Q< Q<', 10, $dynstr_sz );
            $dynamic .= pack( 'Q< Q<', 11, 24 );
            my $main_lbl = $self->labels->{'L_MAIN_START'};

            # Only add DT_INIT for executables, not shared libraries
            # For shared libraries, the init would run on dlopen and can cause issues
            if ( defined $main_lbl && $self->type ne 'shared' ) {
                $dynamic .= pack( 'Q< Q<', 12, $base + $l->get('.text')->{rva} + $main_lbl );    # DT_INIT
            }
            $dynamic .= pack( 'Q< Q<', 0, 0 );
            $l->get('.dynamic')->{size} = length($dynamic);
            $l->calculate(0x1000);
        }

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
        my $sec_idx = 1;
        my %sec_indices;
        for my $s ( $l->sections ) { $sec_indices{ $s->{name} } = $sec_idx++; }

        # 2. Open file and write payloads based on layout
        open my $fh, '>', $f or die $!;
        binmode $fh;
        for my $s ( $l->sections ) {
            my $payload
                = $s->{name} eq '.text'  ? $text :
                $s->{name} eq '.dynstr'  ? $dynstr :
                $s->{name} eq '.dynsym'  ? $dynsym :
                $s->{name} eq '.hash'    ? $hash :
                $s->{name} eq '.dynamic' ? $dynamic :
                ( $s->{name} =~ /^\.(debug|eh_frame)/ ? ( $self->debug_section( $s->{name} ) || "\0" ) : ( $data || "\0" ) );
            $payload .= ( "\0" x ( $s->{size} - length($payload) ) ) if length($payload) < $s->{size};
            seek( $fh, $s->{off}, 0 );
            print $fh $payload;
        }

        # 3. Write Section Header String Table and Section Headers at the end
        my $shstrtab_off = tell($fh);
        print $fh $shstrtab;
        my $shoff = tell($fh);
        my @shdrs = ();

        # NULL Section (index 0)
        push @shdrs, pack( 'L< L< Q< Q< Q< Q< L< L< Q< Q<', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 );

        # Real sections from layout
        for my $s ( $l->sections ) {
            my $type       = 1;    # SHT_PROGBITS
            my $flags      = 0;
            my $sh_link    = 0;
            my $sh_info    = 0;
            my $sh_entsize = 0;
            if ( $s->{name} eq '.text' ) {
                $flags = 6;        # SHF_ALLOC | SHF_EXECINSTR
            }
            elsif ( $s->{name} eq '.data' ) {
                $flags = 3;        # SHF_ALLOC | SHF_WRITE
            }
            elsif ( $s->{name} eq '.dynstr' ) {
                $type  = 3;        # SHT_STRTAB
                $flags = 2;        # SHF_ALLOC
            }
            elsif ( $s->{name} eq '.dynsym' ) {
                $type       = 11;                             # SHT_DYNSYM
                $flags      = 2;                              # SHF_ALLOC
                $sh_link    = $sec_indices{'.dynstr'} // 0;
                $sh_info    = 1;                              # One local symbol (the null symbol)
                $sh_entsize = 24;
            }
            elsif ( $s->{name} eq '.hash' ) {
                $type       = 5;                              # SHT_HASH
                $flags      = 2;                              # SHF_ALLOC
                $sh_link    = $sec_indices{'.dynsym'} // 0;
                $sh_entsize = 4;
            }
            elsif ( $s->{name} eq '.dynamic' ) {
                $type       = 6;                              # SHT_DYNAMIC
                $flags      = 3;                              # SHF_ALLOC | SHF_WRITE
                $sh_link    = $sec_indices{'.dynstr'} // 0;
                $sh_entsize = 16;
            }
            elsif ( $s->{name} =~ /^\.(debug|eh_frame)/ ) {
                $flags = 0;                                   # Debug sections are not loaded
            }
            push @shdrs,
                pack(
                'L< L< Q< Q< Q< Q< L< L< Q< Q<',
                $sh_name_off{ $s->{name} },
                $type,     $flags, ( $flags & 2 ? $base + $s->{rva} : 0 ),
                $s->{off}, $s->{size}, $sh_link, $sh_info, 1, $sh_entsize
                );
        }
        my $shstrtab_idx = scalar(@shdrs);
        push @shdrs, pack( 'L< L< Q< Q< Q< Q< L< L< Q< Q<', $sh_name_off{'.shstrtab'},       3, 0, 0, $shstrtab_off, length($shstrtab), 0, 0, 1, 0 );
        push @shdrs, pack( 'L< L< Q< Q< Q< Q< L< L< Q< Q<', $sh_name_off{'.note.GNU-stack'}, 1, 0, 0, 0,             0,                 0, 0, 1, 0 );
        seek( $fh, $shoff, 0 );
        print $fh $_ for @shdrs;

        # 4. Finalize ELF Header and Program Headers at offset 0
        my $num_ph = 3;    # Headers, Text, Data
        if ($note_data)                { $num_ph++; }
        if ($pintable_data)            { $num_ph++; }
        if ( $self->type eq 'shared' ) { $num_ph++; }
        my $ehdr = pack(
            'A4 C C C C C x7 S< S< L< Q< Q< Q< L< S< S< S< S< S< S<',
            "\x7fELF", 2, 1, 1, $osabi, 0, $elf_type, ( $arch eq 'arm64' ? 183 : 62 ),
            1,         $base + $l->get('.text')->{rva},
            64,        $shoff, 0, 64, 56, $num_ph, 64, scalar(@shdrs), $shstrtab_idx
        );
        my $ph_hdrs = pack( 'L< L< Q< Q< Q< Q< Q< Q<', 1, 4, 0, $base, $base, 0x1000, 0x1000, 0x1000 );
        my $ph_t    = pack(
            'L< L< Q< Q< Q< Q< Q< Q<', 1, 5,    # PT_LOAD, RX
            $l->get('.text')->{off},   $base + $l->get('.text')->{rva}, $base + $l->get('.text')->{rva}, $l->get('.text')->{size},
            $l->get('.text')->{size},  0x1000
        );
        my $d_sec     = $l->get('.data');
        my $d_end_off = $d_sec->{off} + $d_sec->{size};
        if ( $self->type eq 'shared' ) {
            my $dyn_sec = $l->get('.dynamic');
            $d_end_off = $dyn_sec->{off} + $dyn_sec->{size};
        }
        my $d_size = $d_end_off - $d_sec->{off};
        my $ph_d   = pack(
            'L< L< Q< Q< Q< Q< Q< Q<', 1, 6,    # PT_LOAD, RW
            $d_sec->{off}, $base + $d_sec->{rva}, $base + $d_sec->{rva}, $d_size, $d_size, 0x1000
        );
        my $extra_off = 64 + ( $num_ph * 56 );
        my $ph_note   = '';
        if ($note_data) {
            $ph_note
                = pack( 'L< L< Q< Q< Q< Q< Q< Q<', 4, 4, $extra_off, $base + $extra_off, $base + $extra_off, length($note_data), length($note_data),
                4 );
            $extra_off += length($note_data);
        }
        my $ph_syscalls = '';
        if ($pintable_data) {
            $ph_syscalls = pack(
                'L< L< Q< Q< Q< Q< Q< Q<',
                0x65a3dbe9, 4, $extra_off,
                $base + $extra_off,
                $base + $extra_off,
                length($pintable_data), length($pintable_data), 4
            );
            $extra_off += length($pintable_data);
        }
        my $ph_dyn = '';
        if ( $self->type eq 'shared' ) {
            my $d_sec = $l->get('.dynamic');
            $ph_dyn = pack(
                'L< L< Q< Q< Q< Q< Q< Q<',
                2, 6, $d_sec->{off},
                $base + $d_sec->{rva},
                $base + $d_sec->{rva},
                $d_sec->{size}, $d_sec->{size}, 8
            );
        }
        seek( $fh, 0, 0 );
        print $fh $ehdr, $ph_hdrs, $ph_t, $ph_d, $ph_note, $ph_syscalls, $ph_dyn, $note_data, $pintable_data;
        close $fh;
        chmod 0755, $f;
        return $f;
    }
}
1;
__END__

=pod

=head1 NAME

Brocken::Format::ELF - ELF64 binary format writer

=head1 SYNOPSIS

  my $elf = Brocken::Format::ELF->new(type => 'executable');
  $elf->write_bin("out.elf", $code, $data, "x64", "linux");

=head1 DESCRIPTION

Generates 64-bit ELF (Executable and Linkable Format) binaries. Supports both executables and shared libraries. Handles
architecture-specific headers (x64, ARM64) and OS-specific identification (Linux, FreeBSD, NetBSD, OpenBSD, DragonFly).

=head1 METHODS

=head2 image_base()

Returns the default load address (0x400000 for executables, 0 for shared libraries).

=head2 write_bin($filename, $text, $data, $arch, $os, $type = $self->type)

Constructs the ELF file: 1. Calculates section layout. 2. Builds dynamic symbols and hash table (if shared library). 3.
Writes section payloads. 4. Writes section headers and string table. 5. Writes ELF header and program headers.

=cut
