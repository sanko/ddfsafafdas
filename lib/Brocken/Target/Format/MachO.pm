use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';

class Brocken::Target::Format::MachO : isa(Brocken::Format) {
    no warnings 'portable';

    method _setup_layout( $l, $t, $d, $a, $o, $dbg = 0 ) {
        $l->add_section( '.text', $t,  5 );
        $l->add_section( '.data', $d,  3 );
        $l->add_section( '.got',  512, 3 );    # 512 bytes for import pointers (.got)

        # We always allocate .linkedit to hold dyld bind bytecode and symtabs
        $l->add_section( '.linkedit', 4096, 1 );
        if ( $dbg >= 1 ) {
            $l->add_section( '.debug_line',     4096, 0 );
            $l->add_section( '.debug_info',     8192, 0 );
            $l->add_section( '.debug_abbrev',   4096, 0 );
            $l->add_section( '.debug_frame',    8192, 0 );
            $l->add_section( '.debug_aranges',  4096, 0 );
            $l->add_section( '.debug_pubnames', 4096, 0 );
        }
    }

    method import_rva($name) {
        my $imports = { dlopen => 0, dlsym => 8, pthread_create => 16 };
        return $self->layout->get('.got')->{rva} + ( $imports->{$name} // die "Unknown Mach-O import: $name" );
    }
    method image_base () { return 0x100000000; }

    method write_bin( $f, $text, $data, $arch, $os, $type ) {
        my $l              = $self->layout;
        my $base           = $self->image_base;
        my $page_size      = 0x4000;
        my $cputype        = ( $arch eq 'arm64' )        ? 0x0100000c : 0x01000007;
        my $cpusubtype     = ( $arch eq 'arm64' )        ? 0          : 3;
        my $filetype       = ( $self->type eq 'shared' ) ? 6          : 2;            # MH_DYLIB = 6, MH_EXECUTE = 2
        my @debug_sections = grep { $_->{name} =~ /^\.debug/ } $l->sections;
        my $_uleb          = sub {
            my $v   = shift;
            my $out = '';
            do {
                my $byte = $v & 0x7F;
                $v >>= 7;
                $byte |= 0x80 if $v;
                $out .= pack( 'C', $byte );
            } while ($v);
            return $out;
        };

        # 1. Setup LC_LOAD_DYLIB load command for libSystem
        my $lib_name = "/usr/lib/libSystem.B.dylib\0";
        while ( length($lib_name) % 8 != 0 ) { $lib_name .= "\0"; }
        my $lc_load_libsystem = pack( 'L< L< L< L< L< L<', 0xC, 24 + length($lib_name), 24, 2, 0x010000, 0x010000 ) . $lib_name;

        # 2. Setup Dyld Binding Opcode Bytecode Info
        # Binds '_dlopen', '_dlsym', and '_pthread_create' from dylib ordinal 1 to Segment 2 (__DATA), offsets 0, 8, and 16 (in .got)
        my $bind_info = '';
        $bind_info .= pack( 'C', 0x11 );                                                                 # BIND_OPCODE_SET_DYLIB_ORDINAL_IMM | 1
        $bind_info .= pack( 'C', 0x51 );                                                                 # BIND_OPCODE_SET_TYPE_IMM | 1
        $bind_info .= pack( 'C', 0x72 ) . $_uleb->( $l->get('.got')->{rva} - $l->get('.data')->{rva} );  # BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB | 2
        $bind_info .= pack( 'C', 0x40 ) . "_dlopen\0";            # BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM | 0, "_dlopen"
        $bind_info .= pack( 'C', 0x90 );                          # BIND_OPCODE_DO_BIND
        $bind_info .= pack( 'C', 0x40 ) . "_dlsym\0";             # BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM | 0, "_dlsym"
        $bind_info .= pack( 'C', 0x90 );                          # BIND_OPCODE_DO_BIND
        $bind_info .= pack( 'C', 0x40 ) . "_pthread_create\0";    # BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM | 0, "_pthread_create"
        $bind_info .= pack( 'C', 0x90 );                          # BIND_OPCODE_DO_BIND
        $bind_info .= pack( 'C', 0x00 );                          # BIND_OPCODE_DONE
        my $bind_info_size = length($bind_info);
        while ( length($bind_info) % 8 != 0 ) { $bind_info .= "\0"; }

        # 3. Setup Exports & Dynamic Sections (Trie, Symtab)
        my ( $trie, $symtab, $strtab, $lc_id_dylib ) = ( '', '', '', '' );
        my ( $num_syms, $le_off, $trie_size, $symtab_size, $strtab_size ) = ( 0, 0, 0, 0, 0 );
        if ( $self->type eq 'shared' ) {
            require File::Basename;
            my $dylib_name     = File::Basename::basename($f);
            my $dylib_name_pad = $dylib_name . "\0";
            while ( length($dylib_name_pad) % 8 != 0 ) { $dylib_name_pad .= "\0"; }
            $lc_id_dylib = pack( 'L<L< L<L<L<L<', 0xD, 24 + length($dylib_name_pad), 24, 1, 1, 1 ) . $dylib_name_pad;
            my @exports = @{ $self->exported_funcs // [] };
            my %export_rvas;
            for my $name (@exports) {
                $export_rvas{"_$name"} = $l->get('.text')->{rva} + ( $self->labels->{"E_$name"} // 0 );
            }
            my @syms = sort keys %export_rvas;
            $num_syms = scalar @syms;
            $strtab   = "\0";
            my %strx;
            for my $sym (@syms) {
                $strx{$sym} = length($strtab);
                $strtab .= $sym . "\0";
            }
            while ( length($strtab) % 8 != 0 ) { $strtab .= "\0"; }
            for my $sym (@syms) {
                $symtab .= pack( 'L< C C S< Q<', $strx{$sym}, 0x0f, 1, 0, $base + $export_rvas{$sym} );
            }
            if ( $num_syms > 0 ) {
                my @nodes;
                for my $sym (@syms) {
                    my $rva        = $export_rvas{$sym};
                    my $flags_u    = $_uleb->(0);
                    my $rva_u      = $_uleb->($rva);
                    my $term_data  = $flags_u . $rva_u;
                    my $node_bytes = $_uleb->( length($term_data) ) . $term_data . pack( 'C', 0 );
                    push @nodes, { sym => $sym, bytes => $node_bytes };
                }
                my %node_offsets;
                for ( 1 .. 3 ) {
                    my $root = pack( 'C', 0 ) . pack( 'C', $num_syms );
                    for my $n (@nodes) { $root .= $n->{sym} . "\0" . $_uleb->( $node_offsets{ $n->{sym} } // 1024 ); }
                    my $offset = length($root);
                    for my $n (@nodes) {
                        $node_offsets{ $n->{sym} } = $offset;
                        $offset += length( $n->{bytes} );
                    }
                }
                $trie = pack( 'C', 0 ) . pack( 'C', $num_syms );
                for my $n (@nodes) { $trie .= $n->{sym} . "\0" . $_uleb->( $node_offsets{ $n->{sym} } ); }
                for my $n (@nodes) { $trie .= $n->{bytes}; }
                while ( length($trie) % 8 != 0 ) { $trie .= "\0"; }
            }
        }
        $trie_size   = length($trie);
        $symtab_size = length($symtab);
        $strtab_size = length($strtab);

        # Linkedit size covers bind info, trie, symbol table and string table
        $l->get('.linkedit')->{size} = length($bind_info) + $trie_size + $symtab_size + $strtab_size;
        $l->calculate($page_size);
        $le_off = $l->get('.linkedit')->{off};

        # 4. Set up generalized segments and section mapping
        my %seg_names = ( '.text' => '__TEXT', '.data' => '__DATA', '.got' => '__DATA', );
        my %sec_names = ( '.text' => '__text', '.data' => '__data', '.got' => '__got', );
        for my $s ( $l->sections ) {
            if ( $s->{name} =~ /^\.debug_/ ) {
                $seg_names{ $s->{name} } = '__DWARF';
                ( my $macho_name = $s->{name} ) =~ s/^\./__/;
                $sec_names{ $s->{name} } = $macho_name;
            }
        }
        my @text_sections = grep { $_->{name} eq '.text' } $l->sections;
        my $t_sec         = $text_sections[0];
        my @data_sections = grep { $_->{name} eq '.data' || $_->{name} eq '.got' } $l->sections;
        my $t_vmsize      = 0;
        for (@text_sections) { $t_vmsize += $_->{size}; }
        my $t_vmsize_aligned = ( $t_vmsize + $page_size - 1 ) & ~( $page_size - 1 );
        my $t_fileoff        = $t_sec->{off};
        my $d_vmsize         = 0;
        for (@data_sections) { $d_vmsize += $_->{size}; }
        my $d_vmsize_aligned = ( $d_vmsize + $page_size - 1 ) & ~( $page_size - 1 );

        # 5. Build Mach-O Dynamic Load Commands list
        my @cmds = ();
        if ( $self->type ne 'shared' ) {
            push @cmds, pack( 'L<L< a16 Q<Q< Q<Q< L<L<L<L<', 0x19, 72, "__PAGEZERO", 0, $base, 0, 0, 0, 0, 0, 0 );
        }
        my $t_cmd_size = 72 + 80 * scalar(@text_sections);
        my $t_cmd      = pack(
            'L<L< a16 Q<Q< Q<Q< L<L<L<L<',
            0x19, $t_cmd_size, "__TEXT", $base + $text_sections[0]->{rva},
            $t_vmsize_aligned, $t_fileoff, $t_vmsize_aligned, 5, 5, scalar(@text_sections), 0
        );
        for my $s (@text_sections) {
            $t_cmd .= pack(
                'a16 a16 Q<Q< L<L< L<L<L< L<L< L<',
                $sec_names{ $s->{name} },
                "__TEXT",   $base + $s->{rva},
                $s->{size}, $s->{off}, 4, 0, 0, 0x80000400, 0, 0, 0
            );
        }
        push @cmds, $t_cmd;
        my $d_cmd_size = 72 + 80 * scalar(@data_sections);
        my $d_cmd      = pack(
            'L<L< a16 Q<Q< Q<Q< L<L<L<L<',
            0x19,              $d_cmd_size, "__DATA", $base + $data_sections[0]->{rva},
            $d_vmsize_aligned, $data_sections[0]->{off},
            $d_vmsize_aligned, 3, 3, scalar(@data_sections), 0
        );
        for my $s (@data_sections) {
            my $flags = $s->{name} eq '.got' ? 6 : 3;
            $d_cmd .= pack(
                'a16 a16 Q<Q< L<L< L<L<L< L<L< L<',
                $sec_names{ $s->{name} },
                "__DATA",   $base + $s->{rva},
                $s->{size}, $s->{off}, 3, 0, 0, 0, 0, 0, 0
            );
        }
        push @cmds, $d_cmd;
        my $le_sec          = $l->get('.linkedit');
        my $le_size_aligned = ( $le_sec->{size} + $page_size - 1 ) & ~( $page_size - 1 );
        push @cmds,
            pack(
            'L<L< a16 Q<Q< Q<Q< L<L<L<L<',
            0x19, 72, "__LINKEDIT", $base + $le_sec->{rva},
            $le_size_aligned, $le_sec->{off}, $le_sec->{size}, 1, 1, 0, 0
            );
        push @cmds, $lc_id_dylib if $self->type eq 'shared';
        push @cmds, pack( 'L<L< L< a20', 0xE, 32, 12, "/usr/lib/dyld\0\0\0\0\0\0\0" );    # LC_LOAD_DYLINKER
        push @cmds, $lc_load_libsystem;                                                   # LC_LOAD_DYLIB pointing to libSystem

        # LC_DYLD_INFO_ONLY
        my $export_off = $self->type eq 'shared' ? $le_off + length($bind_info) : 0;
        my $export_sz  = $self->type eq 'shared' ? $trie_size                   : 0;
        push @cmds, pack(
            'L<L< L<L< L<L< L<L< L<L< L<L<', 0x80000022, 48, 0, 0,    # rebase
            $le_off,     $bind_info_size,                             # bind
            0,           0,                                           # weak
            0,           0,                                           # lazy
            $export_off, $export_sz                                   # export
        );

        # LC_SYMTAB
        my $symtab_off = $le_off + length($bind_info) + $trie_size;
        push @cmds, pack( 'L<L< L<L< L<L<', 0x2, 24, $symtab_off, $num_syms, $symtab_off + $symtab_size, $strtab_size );

        # LC_DYSYMTAB
        push @cmds, pack( 'L<L< L<L< L<L< L<L< L<L<', 0xB, 80, 0, 0, 0, $num_syms, $num_syms, 0 ) . ( "\0" x 48 );
        push @cmds, pack( 'L<L< Q<Q< Q<', 0x80000028, 24, $t_sec->{off}, 0, 0 ) if $self->type eq 'exe';    # LC_MAIN
        if (@debug_sections) {
            my $cmdsize      = 72 + 80 * scalar(@debug_sections);
            my $dw_start_rva = $debug_sections[0]->{rva};
            my $dw_start_off = $debug_sections[0]->{off};
            my $dw_size      = 0;
            for (@debug_sections) { $dw_size += $_->{size}; }
            my $dw_size_aligned = ( $dw_size + $page_size - 1 ) & ~( $page_size - 1 );
            my $dw_cmd          = pack(
                'L<L< a16 Q<Q< Q<Q< L<L<L<L<',
                0x19, $cmdsize, "__DWARF", $base + $dw_start_rva,
                $dw_size_aligned, $dw_start_off, $dw_size_aligned, 0, 0, scalar(@debug_sections), 0
            );
            for my $s (@debug_sections) {
                $dw_cmd .= pack(
                    'a16 a16 Q<Q< L<L< L<L<L< L<L< L<',
                    $sec_names{ $s->{name} },
                    "__DWARF",  $base + $s->{rva},
                    $s->{size}, $s->{off}, 0, 0, 0, 0, 0, 0, 0
                );
            }
            push @cmds, $dw_cmd;
        }
        my $ncmds      = scalar(@cmds);
        my $sizeofcmds = 0;
        for (@cmds) { $sizeofcmds += length($_); }

        # Write Mach-O header and command payloads
        open my $fh, '>', $f or die $!;
        binmode $fh;
        my $flags = 0x200085 | 0x00200000;               # MH_PIE | ...
        $flags = 0x100085 if $self->type eq 'shared';    # MH_DYLIB | NOUNDEFS | TWOLEVEL
        print $fh pack( 'L<L<L<L<L<L<L<L<', 0xfeedfacf, $cputype, $cpusubtype, $filetype, $ncmds, $sizeofcmds, $flags, 0 );
        print $fh $_ for @cmds;

        # 6. Write Section Payloads
        seek( $fh, $t_sec->{off}, 0 );
        print $fh $text;
        my $d_sec_actual = $l->get('.data');
        seek( $fh, $d_sec_actual->{off}, 0 );
        print $fh $data // '';
        my $got_sec = $l->get('.got');
        seek( $fh, $got_sec->{off}, 0 );

        # Correctly align got section
        print $fh pack( 'Q< Q< Q<', 0, 0, 0 );
        seek( $fh, $le_sec->{off}, 0 );
        print $fh $bind_info . $trie . $symtab . $strtab;
        if (@debug_sections) {
            for my $s (@debug_sections) {
                seek( $fh, $s->{off}, 0 );
                my $dw_payload = $self->debug_section( $s->{name} ) || '';
                print $fh $dw_payload;
            }
        }
        close $fh;
        chmod 0755, $f;
        return $f;
    }
}
1;
__END__

=pod

=head1 NAME

Brocken::Format::MachO - Mach-O (macOS) binary format writer

=head1 SYNOPSIS

  my $macho = Brocken::Format::MachO->new(type => 'executable');
  $macho->write_bin("out.macho", $code, $data, "x64", "macos");

=head1 DESCRIPTION

Generates 64-bit Mach-O (Mach Object) binaries for macOS.  Supports: - Executables and Dynamic Libraries (MH_DYLIB). -
LC_MAIN for executables. - Export Tries and Symbol Tables for libraries. - DWARF debug sections (mapped into __DWARF
segment).

=head1 METHODS

=head2 image_base()

Returns the default load address 0x100000000.

=head2 write_bin($filename, $text, $data, $arch, $os)

Constructs and writes the Mach-O file: 1. Calculates layout. 2. Writes Mach-O header. 3. Writes Load Commands
(__PAGEZERO, __TEXT, __DATA, __LINKEDIT, LC_DYLD_INFO_ONLY, LC_SYMTAB, LC_DYSYMTAB, LC_MAIN, etc.). 4. Writes Segment
and Section descriptors. 5. Writes section payloads at correct page-aligned offsets.

=cut
