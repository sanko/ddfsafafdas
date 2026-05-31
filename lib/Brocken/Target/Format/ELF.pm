use v5.40;
use feature 'class';
no warnings 'experimental::class';

class Brocken::Target::Format::ELF : isa(Brocken::Format) {

    method _detect_elf_info ( $ref = undef ) {
        my @candidates = $ref ? ($ref) : ( '/bin/sh', '/sbin/init', '/usr/bin/env', '/boot/system/bin/sh', '/boot/system/bin/env' );
        for my $candidate (@candidates) {
            next if !-e $candidate || !-r _;
            open my $fh, '<:raw', $candidate or next;
            my $bytes = read( $fh, my $ehdr, 64 );
            close $fh;
            next if $bytes != 64;
            next if substr( $ehdr, 0, 4 ) ne "\x7fELF";
            my $osabi    = ord( substr( $ehdr, 7, 1 ) );
            my $ei_class = ord( substr( $ehdr, 4, 1 ) );
            next if $ei_class != 1 && $ei_class != 2;
            my ( $e_phoff, $e_phentsize, $e_phnum );

            if ( $ei_class == 2 ) {
                $e_phoff     = unpack( 'Q', substr( $ehdr, 32, 8 ) );
                $e_phentsize = unpack( 'S', substr( $ehdr, 54, 2 ) );
                $e_phnum     = unpack( 'S', substr( $ehdr, 56, 2 ) );
            }
            else {
                $e_phoff     = unpack( 'L', substr( $ehdr, 28, 4 ) );
                $e_phentsize = unpack( 'S', substr( $ehdr, 42, 2 ) );
                $e_phnum     = unpack( 'S', substr( $ehdr, 44, 2 ) );
            }
            next if !$e_phnum || !$e_phentsize;
            open my $fh2, '<:raw', $candidate or next;
            seek( $fh2, $e_phoff, 0 );
            my $ph_bytes = $e_phentsize * $e_phnum;
            my $read_ok  = read( $fh2, my $phdrs, $ph_bytes );
            close $fh2;
            next if !$read_ok;
            my ( $note_data, $has_pintable ) = ( '', 0 );

            for my $i ( 0 .. $e_phnum - 1 ) {
                my $phdr   = substr( $phdrs, $i * $e_phentsize, $e_phentsize );
                my $p_type = unpack( 'L', substr( $phdr, 0, 4 ) );
                if ( $p_type == 4 && !$note_data ) {
                    my ( $p_offset, $p_filesz );
                    if ( $ei_class == 2 ) {
                        $p_offset = unpack( 'Q', substr( $phdr, 8,  8 ) );
                        $p_filesz = unpack( 'Q', substr( $phdr, 32, 8 ) );
                    }
                    else {
                        $p_offset = unpack( 'L', substr( $phdr, 4,  4 ) );
                        $p_filesz = unpack( 'L', substr( $phdr, 16, 4 ) );
                    }
                    open my $fh3, '<:raw', $candidate or next;
                    seek( $fh3, $p_offset, 0 );
                    read( $fh3, $note_data, $p_filesz );
                    close $fh3;
                }
                elsif ( $p_type == 0x65a3dbe9 && !$has_pintable ) {
                    $has_pintable = 1;
                }
            }
            return ( $osabi, $note_data, $has_pintable );
        }
        return ( 0, '', 0 );
    }

    method _setup_layout( $l, $t, $d, $a, $o, $dbg = 0 ) {
        $l->add_section( '.text', $t, 5 );    # RX
        $l->add_section( '.data', $d, 6 );    # RW

        # We add dynamic sections for both executables and shared libraries to support dynamic imports (FFI)
        $l->add_section( '.interp',   512,  2 ) if $self->type eq 'exe';
        $l->add_section( '.dynstr',   4096, 2 );
        $l->add_section( '.dynsym',   4096, 2 );
        $l->add_section( '.rela.dyn', 4096, 2 );
        $l->add_section( '.hash',     4096, 2 );
        $l->add_section( '.dynamic',  4096, 3 );
        $l->add_section( '.got',      512,  6 );                           # RW (writable for dynamic linker patching)

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

    method import_rva($name) {
        my $imports = { dlopen => 0, dlsym => 8, pthread_create => 16 };
        return $self->layout->get('.got')->{rva} + ( $imports->{$name} // die "Unknown ELF import: $name" );
    }
    method image_base () { return $self->type eq 'shared' ? 0 : 0x400000; }

    method write_bin( $f, $text, $data, $arch, $os, $type = $self->type ) {
        my $l        = $self->layout;
        my $base     = $self->image_base;
        my $elf_type = $type eq 'shared' ? 3 : 2;    # ET_DYN or ET_EXEC

        # Probe system binaries for the correct OSABI and PT_NOTE data
        my ( $osabi, $note_data, $has_pintable ) = $self->_detect_elf_info();

        # Per-OS interpreter path for dynamic executables
        my %interp_map = (
            linux       => '/lib64/ld-linux-x86-64.so.2',
            linux_arm   => '/lib/ld-linux-aarch64.so.1',
            freebsd     => '/libexec/ld-elf.so.1',
            netbsd      => '/usr/libexec/ld.elf_so',
            openbsd     => '/usr/libexec/ld.so',
            dragonfly   => '/libexec/ld-elf.so.2',
            solaris     => '/lib/64/ld.so.1',
            midnightbsd => '/libexec/ld-elf.so.1',
            haiku       => '',
        );

        # Per-OS libc name for DT_NEEDED
        my %libc_map = (
            linux       => 'libc.so.6',
            freebsd     => 'libc.so.7',
            netbsd      => 'libc.so.12',
            openbsd     => 'libc.so.98.1',
            dragonfly   => 'libc.so.8',
            solaris     => 'libc.so.1',
            midnightbsd => 'libc.so.7',
            haiku       => 'libroot.so',
        );

        # Generate pintable data for OpenBSD (syscall allowlisting)
        my $pintable_data = '';
        if ($has_pintable) {
            my $pos      = 0;
            my $text_rva = $l->get('.text')->{rva};
            if ( $arch eq 'x64' ) {
                while ( ( my $idx = index( $text, "\x0F\x05", $pos ) ) != -1 ) {
                    my $vaddr = $base + $text_rva + $idx;
                    $pintable_data .= pack( 'L<L<', $vaddr, 1 );
                    $pintable_data .= pack( 'L<L<', $vaddr, 4 );
                    $pos = $idx + 2;
                }
            }
            else {
                while ( ( my $idx = index( $text, "\x01\x00\x00\xd4", $pos ) ) != -1 ) {
                    my $vaddr = $base + $text_rva + $idx;
                    $pintable_data .= pack( 'L<L<', $vaddr, 1 );
                    $pintable_data .= pack( 'L<L<', $vaddr, 4 );
                    $pos = $idx + 4;
                }
            }
        }

        # 1. Setup Interp path for executable
        my $interp     = '';
        my $has_interp = 0;
        if ( $self->type eq 'exe' ) {
            my $interp_key = ( $arch eq 'arm64' && $os eq 'linux' ) ? 'linux_arm' : $os;
            my $ipath      = $interp_map{$interp_key} // '/lib/ld.so.1';
            if ( length $ipath ) {
                $interp                    = $ipath . "\0";
                $l->get('.interp')->{size} = length($interp);
                $has_interp                = 1;
            }
        }

        # 2. Setup Dynamic Strings Table
        my @exports = @{ $self->exported_funcs // [] };
        my @imports = ( 'dlopen', 'dlsym', 'pthread_create' );
        my $libc    = $libc_map{$os} // 'libc.so';
        my @libs    = ($libc);
        my $dynstr  = "\0";
        my %str_off;
        for my $s ( @libs, @imports, @exports ) {
            next if exists $str_off{$s};
            $str_off{$s} = length($dynstr);
            $dynstr .= $s . "\0";
        }
        $l->get('.dynstr')->{size} = length($dynstr);

        # 3. Setup Dynamic Symbol Table
        my $dynsym  = pack( 'L< C C S< Q< Q<', 0, 0, 0, 0, 0, 0 );    # Null symbol
        my $sym_idx = 1;
        my %sym_indices;

        # Undefined dynamic imports
        for my $name (@imports) {
            $sym_indices{$name} = $sym_idx++;
            $dynsym .= pack( 'L< C C S< Q< Q<', $str_off{$name}, 0x12, 0, 0, 0, 0 );
        }

        # Exports if shared library
        if ( $self->type eq 'shared' ) {
            for my $name (@exports) {
                my $rva = $l->get('.text')->{rva} + ( $self->labels->{"E_$name"} // 0 );
                $sym_indices{$name} = $sym_idx++;

                # Section index 1 is .text (first section after null)
                $dynsym .= pack( 'L< C C S< Q< Q<', $str_off{$name}, 0x12, 0, 1, $base + $rva, 0 );
            }
        }
        $l->get('.dynsym')->{size} = length($dynsym);

        # 4. Setup Relocations (.rela.dyn)
        my $got_rva        = $l->get('.got')->{rva};
        my $rel_type       = ( $arch eq 'arm64' ) ? 1025 : 6;    # R_AARCH64_GLOB_DAT or R_X86_64_GLOB_DAT
        my $rela_dyn       = '';
        my $dlopen_slot    = $base + $got_rva + 0;
        my $dlopen_sym_idx = $sym_indices{'dlopen'};
        $rela_dyn .= pack( 'Q< Q< q<', $dlopen_slot, ( $dlopen_sym_idx << 32 ) | $rel_type, 0 );
        my $dlsym_slot    = $base + $got_rva + 8;
        my $dlsym_sym_idx = $sym_indices{'dlsym'};
        $rela_dyn .= pack( 'Q< Q< q<', $dlsym_slot, ( $dlsym_sym_idx << 32 ) | $rel_type, 0 );
        my $pthread_slot    = $base + $got_rva + 16;
        my $pthread_sym_idx = $sym_indices{'pthread_create'};
        $rela_dyn .= pack( 'Q< Q< q<', $pthread_slot, ( $pthread_sym_idx << 32 ) | $rel_type, 0 );
        $l->get('.rela.dyn')->{size} = length($rela_dyn);

        # 5. Setup GOT section payload (just three zeroed slots)
        my $got = pack( 'Q< Q< Q<', 0, 0, 0 );
        $l->get('.got')->{size} = length($got);

        # 6. Setup Hash Table
        my $elf_hash = sub {
            my $name = shift;
            my $h    = 0;
            for my $c ( split //, $name ) {
                $h = ( $h << 4 ) + ord($c);
                $h &= 0xffffffff;
                my $g = $h & 0xf0000000;
                if ($g) { $h ^= ( $g >> 24 ); }
                $h &= 0x0fffffff;
            }
            return $h;
        };
        my $nbucket = 3;
        my $nchain  = $sym_idx;
        my @buckets = (0) x $nbucket;
        my @chains  = (0) x $nchain;
        for my $name ( keys %sym_indices ) {
            my $idx = $sym_indices{$name};
            my $h   = $elf_hash->($name);
            my $b   = $h % $nbucket;
            $chains[$idx] = $buckets[$b];
            $buckets[$b]  = $idx;
        }
        my $hash = pack( 'L<*', $nbucket, $nchain, @buckets, @chains );
        $l->get('.hash')->{size} = length($hash);

        # Calculate to stabilize RVAs before building .dynamic
        $l->calculate(0x1000);

        # 7. Setup .dynamic payload
        my $dyn_rva        = $l->get('.dynamic')->{rva};
        my $str_rva        = $l->get('.dynstr')->{rva};
        my $sym_rva        = $l->get('.dynsym')->{rva};
        my $hash_rva       = $l->get('.hash')->{rva};
        my $rela_rva       = $l->get('.rela.dyn')->{rva};
        my $got_rva_actual = $l->get('.got')->{rva};
        my $dynamic        = '';
        $dynamic .= pack( 'Q< Q<', 1,  $str_off{$libc} );            # DT_NEEDED
        $dynamic .= pack( 'Q< Q<', 4,  $base + $hash_rva );          # DT_HASH
        $dynamic .= pack( 'Q< Q<', 5,  $base + $str_rva );           # DT_STRTAB
        $dynamic .= pack( 'Q< Q<', 6,  $base + $sym_rva );           # DT_SYMTAB
        $dynamic .= pack( 'Q< Q<', 10, length($dynstr) );            # DT_STRSZ
        $dynamic .= pack( 'Q< Q<', 11, 24 );                         # DT_SYMENT
        $dynamic .= pack( 'Q< Q<', 7,  $base + $rela_rva );          # DT_RELA
        $dynamic .= pack( 'Q< Q<', 8,  length($rela_dyn) );          # DT_RELASZ
        $dynamic .= pack( 'Q< Q<', 9,  24 );                         # DT_RELAENT
        $dynamic .= pack( 'Q< Q<', 3,  $base + $got_rva_actual );    # DT_PLTGOT
        my $main_lbl = $self->labels->{'L_MAIN_START'};

        if ( defined $main_lbl && $self->type ne 'shared' ) {
            $dynamic .= pack( 'Q< Q<', 12, $base + $l->get('.text')->{rva} + $main_lbl );    # DT_INIT
        }
        $dynamic .= pack( 'Q< Q<', 0, 0 );                                                   # DT_NULL
        $l->get('.dynamic')->{size} = length($dynamic);

        # Final layout calculation
        $l->calculate(0x1000);

        # Build Section Names String Table (.shstrtab)
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

        # Open file and write payloads based on layout
        open my $fh, '>', $f or die $!;
        binmode $fh;
        for my $s ( $l->sections ) {
            my $payload
                = $s->{name} eq '.text'   ? $text :
                $s->{name} eq '.interp'   ? $interp :
                $s->{name} eq '.dynstr'   ? $dynstr :
                $s->{name} eq '.dynsym'   ? $dynsym :
                $s->{name} eq '.rela.dyn' ? $rela_dyn :
                $s->{name} eq '.hash'     ? $hash :
                $s->{name} eq '.dynamic'  ? $dynamic :
                $s->{name} eq '.got'      ? $got :
                ( $s->{name} =~ /^\.(debug|eh_frame)/ ? ( $self->debug_section( $s->{name} ) || "\0" ) : ( $data || "\0" ) );
            $payload .= ( "\0" x ( $s->{size} - length($payload) ) ) if length($payload) < $s->{size};
            seek( $fh, $s->{off}, 0 );
            print $fh $payload;
        }

        # Write Section Header String Table and Section Headers at the end
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
            elsif ( $s->{name} eq '.interp' ) {
                $type  = 1;        # SHT_PROGBITS
                $flags = 2;        # SHF_ALLOC
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
            elsif ( $s->{name} eq '.rela.dyn' ) {
                $type       = 4;                              # SHT_RELA
                $flags      = 2;                              # SHF_ALLOC
                $sh_link    = $sec_indices{'.dynsym'} // 0;
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
            elsif ( $s->{name} eq '.got' ) {
                $type       = 1;                              # SHT_PROGBITS
                $flags      = 3;                              # SHF_ALLOC | SHF_WRITE
                $sh_entsize = 8;
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

        # Program Headers
        my $num_ph = 4;                       # PT_PHDR, PT_LOAD (RX), PT_LOAD (RW), PT_DYNAMIC
        if ($has_interp)    { $num_ph++; }    # PT_INTERP
        if ($note_data)     { $num_ph++; }    # PT_NOTE
        if ($pintable_data) { $num_ph++; }    # PT_OPENBSD_PINTABLE
        my @phdrs = ();

        # 1. PT_PHDR (type 6)
        push @phdrs, pack( 'L< L< Q< Q< Q< Q< Q< Q<', 6, 4, 64, $base + 64, $base + 64, $num_ph * 56, $num_ph * 56, 8 );

        # 2. PT_INTERP (type 3)
        if ($has_interp) {
            my $interp_sec = $l->get('.interp');
            push @phdrs,
                pack(
                'L< L< Q< Q< Q< Q< Q< Q<',
                3, 4, $interp_sec->{off},
                $base + $interp_sec->{rva},
                $base + $interp_sec->{rva},
                $interp_sec->{size}, $interp_sec->{size}, 1
                );
        }

        # 3. PT_LOAD (type 1) RX segment (Headers + .text)
        my $text_sec = $l->get('.text');
        push @phdrs,
            pack(
            'L< L< Q< Q< Q< Q< Q< Q<',
            1, 5, 0, $base, $base,
            $text_sec->{off} + $text_sec->{size},
            $text_sec->{off} + $text_sec->{size}, 0x1000
            );

        # 4. PT_LOAD (type 1) RW segment (Covers .data through .got)
        my $data_sec = $l->get('.data');
        my $got_sec  = $l->get('.got');
        my $rw_size  = ( $got_sec->{off} + $got_sec->{size} ) - $data_sec->{off};
        push @phdrs,
            pack( 'L< L< Q< Q< Q< Q< Q< Q<', 1, 6, $data_sec->{off}, $base + $data_sec->{rva}, $base + $data_sec->{rva}, $rw_size, $rw_size, 0x1000 );

        # 5. PT_DYNAMIC (type 2)
        my $dyn_sec = $l->get('.dynamic');
        push @phdrs,
            pack(
            'L< L< Q< Q< Q< Q< Q< Q<',
            2, 6, $dyn_sec->{off},
            $base + $dyn_sec->{rva},
            $base + $dyn_sec->{rva},
            $dyn_sec->{size}, $dyn_sec->{size}, 8
            );
        my $extra_off   = 64 + ( $num_ph * 56 );
        my $note_header = '';
        if ($note_data) {
            push @phdrs,
                pack( 'L< L< Q< Q< Q< Q< Q< Q<', 4, 4, $extra_off, $base + $extra_off, $base + $extra_off, length($note_data), length($note_data),
                4 );
            $extra_off += length($note_data);
        }
        my $syscalls_header = '';
        if ($pintable_data) {
            push @phdrs,
                pack(
                'L< L< Q< Q< Q< Q< Q< Q<',
                0x65a3dbe9, 4, $extra_off,
                $base + $extra_off,
                $base + $extra_off,
                length($pintable_data), length($pintable_data), 4
                );
            $extra_off += length($pintable_data);
        }

        # Finalize ELF Header and write program headers/extra data
        my $ehdr = pack(
            'A4 C C C C C x7 S< S< L< Q< Q< Q< L< S< S< S< S< S< S<',
            "\x7fELF", 2, 1, 1, $osabi, 0, $elf_type, ( $arch eq 'arm64' ? 183 : 62 ),
            1,         $base + $l->get('.text')->{rva},
            64,        $shoff, 0, 64, 56, $num_ph, 64, scalar(@shdrs), $shstrtab_idx
        );
        seek( $fh, 0, 0 );
        print $fh $ehdr, @phdrs, $note_data, $pintable_data;
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
