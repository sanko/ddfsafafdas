package Brocken::Target::Format::PE;
use v5.40;
use feature 'class';
no warnings 'portable';
no warnings 'experimental::class';
use File::Basename qw(basename);

class Brocken::Target::Format::PE : isa(Brocken::Format) {
    no warnings 'portable';
    our %IMPORTS = (
        ExitProcess                 => 0,
        GetStdHandle                => 8,
        WriteFile                   => 16,
        VirtualAlloc                => 24,
        SetConsoleOutputCP          => 32,
        AddVectoredExceptionHandler => 40,
        CreateEventA                => 48,
        SetEvent                    => 56,
        WaitForSingleObject         => 64,
        CloseHandle                 => 72,
        CreateFileA                 => 80,
        ReadFile                    => 88,
        GetFileSizeEx               => 96,
        GetEnvironmentStringsA      => 104,
        FreeEnvironmentStringsA     => 112,
        GetCurrentProcessId         => 120,
        GetModuleFileNameA          => 128,
        GetSystemTimeAsFileTime     => 136,
        GetCommandLineA             => 144,
        LoadLibraryA                => 152,
        GetProcAddress              => 160,
        CreateThread                => 168
    );

    method import_rva($n) {
        return $self->rva_for('.idata') + ( $IMPORTS{$n} // die "Unknown PE import: $n" );
    }

    method _setup_layout( $l, $t, $d, $a, $o, $dbg = 0 ) {
        $l->add_section( '.text',  $t,                    0x60000020 );
        $l->add_section( '.data',  ( $d > 0 ? $d : 512 ), 0xC0000040 );
        $l->add_section( '.idata', 2048,                  0xC0000040 );
        #
        if ( $o eq 'win64' ) {
            $l->add_section( '.pdata', 4096, 0x42000040 );
            $l->add_section( '.xdata', 4096, 0x42000040 );
        }
        if ( $self->type eq 'shared' ) {
            warn "PE: Adding .edata section\n" if $ENV{BROCKEN_JIT_DEBUG};
            $l->add_section( '.edata', 2048, 0x40000040 );
        }
        if ( $dbg >= 1 ) {
            $l->add_section( '.debug_line',     4096, 0x42000040 );
            $l->add_section( '.debug_info',     8192, 0x42000040 );
            $l->add_section( '.debug_abbrev',   4096, 0x42000040 );
            $l->add_section( '.debug_frame',    8192, 0x42000040 );
            $l->add_section( '.debug_aranges',  4096, 0x42000040 );
            $l->add_section( '.debug_pubnames', 4096, 0x42000040 );
        }
    }
    method image_base () { return 0x140000000; }

    method write_bin( $filename, $text, $data, $arch, $os, $type ) {
        warn "PE: write_bin start\n" if $ENV{BROCKEN_JIT_DEBUG};
        my $l         = $self->layout;
        my $fa        = $l->file_align;
        my $sa        = $l->section_align;
        my $base      = $self->image_base;
        my $idata_rva = $l->get('.idata')->{rva};
        my $idata_raw = $self->_build_idata_raw($idata_rva);
        warn "PE: idata built\n" if $ENV{BROCKEN_JIT_DEBUG};
        my ( $edata_data, $edata_rva, $edata_size ) = ( '', 0, 0 );

        if ( $self->type eq 'shared' ) {
            warn "PE: building edata...\n" if $ENV{BROCKEN_JIT_DEBUG};
            $edata_rva                = $l->get('.edata')->{rva};
            $edata_data               = $self->_build_edata_raw( $edata_rva, $filename );
            $edata_size               = length($edata_data);
            $l->get('.edata')->{size} = $edata_size;
            $l->calculate(0x1000);    # Recalculate offsets/RVAs
            warn "PE: edata built, size=$edata_size\n" if $ENV{BROCKEN_JIT_DEBUG};
        }

        # Build SEH .pdata / .xdata sections
        my ( $pdata_data, $xdata_data ) = ( '', '' );
        my $pdata_rva  = 0;
        my $pdata_size = 0;
        if ( $os eq 'win64' && $arch eq 'x64' && $self->func_ranges && @{ $self->func_ranges } ) {
            warn "PE: Building .pdata for " . scalar( @{ $self->func_ranges } ) . " functions.\n" if $ENV{BROCKEN_JIT_DEBUG};
            warn "PE: building SEH...\n"                                                          if $ENV{BROCKEN_JIT_DEBUG};
            $xdata_data               = $self->_build_xdata;
            $pdata_data               = $self->_build_pdata( $l->get('.text')->{rva}, $l->get('.xdata')->{rva} );
            $l->get('.pdata')->{size} = length($pdata_data);
            $l->get('.xdata')->{size} = length($xdata_data);
            $pdata_rva                = $l->get('.pdata')->{rva};
            $pdata_size               = length($pdata_data);
        }
        if ( $ENV{BROCKEN_JIT_DEBUG} ) {
            for my $s ( $l->sections ) {
                warn "PE: Section " . $s->{name} . " size=" . $s->{size} . "\n";
            }
        }
        my $image_size = $l->calculate(0x1000);
        warn "PE: layout calculated, image_size=$image_size\n" if $ENV{BROCKEN_JIT_DEBUG};
        my $m_type = ( $arch eq 'arm64' ? 0xAA64 : 0x8664 );
        open my $fh, '>', $filename or die $!;
        binmode $fh;
        print $fh pack( 'S< x58 L<', 0x5A4D, 0x80 ), pack( 'a64', "Brocken AOT\n\$" ), pack( 'L<', 0x4550 );

        # Build COFF string table for long section names
        my %sec_name;
        my $strtab = '';
        for my $s ( $l->sections ) {
            if ( length( $s->{name} ) > 8 ) {
                $sec_name{ $s->{name} } = sprintf( "/%d", 4 + length($strtab) );
                $strtab .= $s->{name} . "\0";
            }
            else { $sec_name{ $s->{name} } = $s->{name}; }
        }
        my $num_syms        = length($strtab)             ? 1                                                : 0;
        my $sym_off         = $num_syms                   ? ( 132 + 20 + 240 + scalar( $l->sections ) * 40 ) : 0;
        my $characteristics = ( $self->type eq 'shared' ) ? 0x2022                                           : 0x0022;
        print $fh pack( 'S< S< L< L< L< S< S<', $m_type, scalar( $l->sections ), time(), $sym_off, $num_syms, 240, $characteristics );

        # Optional Header
        my $soc  = ( $l->get('.text')->{size} + $fa - 1 ) & ~( $fa - 1 );
        my $soid = 0;
        for my $s ( $l->sections ) {
            $soid += ( $s->{size} + $fa - 1 ) & ~( $fa - 1 ) if $s->{flags} & 0x40;
        }
        print $fh pack(
            'S< C C L< L< L< L< L< Q< L< L< S< S< S< S< S< S< L< L< L< L< S< S< Q< Q< Q< Q< L< L<',
            0x20B, 14, 0, $soc, $soid, 0,
            ( $self->type eq 'shared' ) ? 0 : $l->get('.text')->{rva},
            $l->get('.text')->{rva},
            $base, $sa, $fa, 6, 0, 0, 0, 6, 0, 0, $image_size, $l->header_size, 0, 3, 0x8100, 0x100000, $sa, 0x100000, $sa, 0, 16
        );

        # Data Directory Entries (16 standard entries)
        my $iat_len = ( scalar( keys %IMPORTS ) + 1 ) * 8;
        my $dir_rva = $idata_rva + $iat_len * 2;
        print $fh pack( 'L< L<', $edata_rva, $edata_size );    # 0: Export
        print $fh pack( 'L< L<', $dir_rva,   40 );             # 1: Import
        print $fh pack( 'L< L<', 0,          0 );              # 2: Resource
        print $fh pack( 'L< L<', $pdata_rva, $pdata_size );    # 3: Exception (.pdata)
        print $fh pack( 'L< L<', 0,          0 ) x 8;          # 4-11: reserved
        print $fh pack( 'L< L<', $idata_rva, $iat_len );       # 12: IAT
        print $fh pack( 'L< L<', 0,          0 ) x 3;          # 13-15: reserved

        for my $s ( $l->sections ) {
            my $raw_size = ( $s->{size} + $fa - 1 ) & ~( $fa - 1 );
            print $fh pack(
                'a8 L< L< L< L< L< L< S< S< L<',
                $sec_name{ $s->{name} },
                $s->{size}, $s->{rva}, $raw_size, $s->{off}, 0, 0, 0, 0, $s->{flags}
            );
        }
        if ($num_syms) {
            print $fh pack('x18');                                    # 1 dummy COFF symbol entry (18 null bytes)
            print $fh pack( 'L<', length($strtab) + 4 ) . $strtab;    # string table
        }
        print $fh ( "\0" x ( $l->header_size - tell($fh) ) );
        for my $s ( $l->sections ) {
            my $payload
                = $s->{name} eq '.text' ? $text :
                $s->{name} eq '.idata'  ? $idata_raw :
                $s->{name} eq '.edata'  ? $edata_data :
                $s->{name} eq '.pdata'  ? $pdata_data :
                $s->{name} eq '.xdata'  ? $xdata_data :
                ( $s->{name} =~ /^\.debug/ ? ( $self->debug_section( $s->{name} ) || "\0" ) : ( $data || "\0" ) );
            my $file_size = ( $s->{size} + $fa - 1 ) & ~( $fa - 1 );
            $payload .= "\0" x ( $file_size - length($payload) ) if length($payload) < $file_size;
            $payload = substr( $payload, 0, $file_size );
            seek( $fh, $s->{off}, 0 );
            print $fh $payload;
        }
        close $fh;
        return $filename;
    }

    method _build_idata_raw($base_rva) {
        my @funcs        = sort { $IMPORTS{$a} <=> $IMPORTS{$b} } keys %IMPORTS;
        my $iat_len      = ( scalar(@funcs) + 1 ) * 8;
        my $ilt_len      = $iat_len;
        my $dir_len      = 20;
        my $null_dir_len = 20;
        my $dll_name     = "kernel32.dll\0";
        my $dll_name_len = length($dll_name);
        my $hints_rva    = $base_rva + $iat_len + $ilt_len + $dir_len + $null_dir_len + $dll_name_len;
        my ( $iat, $hints ) = ( '', '' );

        for my $f (@funcs) {
            $iat   .= pack( 'Q<', $hints_rva + length($hints) );
            $hints .= pack( 'S<', 0 ) . $f . "\0";
            $hints .= "\0" if length($hints) % 2 != 0;
        }
        $iat .= pack( 'Q<', 0 );
        my $ilt          = $iat;
        my $ilt_rva      = $base_rva + $iat_len;
        my $dir_rva      = $ilt_rva + $ilt_len;
        my $dll_name_rva = $dir_rva + $dir_len + $null_dir_len;
        my $dir          = pack( 'L< L< L< L< L<', $ilt_rva, 0, 0, $dll_name_rva, $base_rva );
        my $null_dir     = pack( 'L< L< L< L< L<', 0,        0, 0, 0,             0 );
        my $block        = $iat . $ilt . $dir . $null_dir . $dll_name . $hints;
        my $pad_len      = 2048 - length($block);
        $pad_len = 0 if $pad_len < 0;
        return $block . ( "\0" x $pad_len );
    }

    method _build_xdata () {
        # SEH register numbers (AMD64 ABI)
        my %SEH_REG = (
            rax => 0, rcx => 1, rdx => 2, rbx => 3, rsp => 4, rbp => 5, rsi => 6, rdi => 7,
            r8  => 8, r9  => 9, r10 => 10, r11 => 11, r12 => 12, r13 => 13, r14 => 14, r15 => 15
        );
        my @regs      = @{ $self->preserved_regs // [] };

        # Replicate exact frame size calculation from Pipeline.pm
        my $locals    = 2048;
        my $shadow    = 32;
        my $total_loc = $locals + $shadow;
        my $offset_regs = ( 1 + scalar(@regs) ) * 8;
        my $base   = ( $total_loc + 15 ) & ~15;
        my $rem    = ( $offset_regs + $base ) % 16;
        my $fsz    = $rem == 0 ? $base : $base + ( 16 - $rem );
        my $scaled = $fsz / 8;

        my $codes     = '';
        my $offset = 0;
        my @push_info;

        # Windows preserved regs: rbp, rbx, rdi, rsi, r12, r13, r14, r15
        # We push rbp first (due to enter_func / push_frame prologue order):
        # push rbp (1 byte)
        # mov rbp, rsp (3 bytes, total offset so far = 4)
        # then push rbx, rdi, rsi, r12, r13, r14, r15

        # push rbp
        $offset += 1;
        push @push_info, { reg_num => $SEH_REG{rbp}, offset => $offset };

        # mov rbp, rsp (3 bytes) -> offset = 4
        $offset += 3;

        # push remaining preserved registers
        my @remaining = @regs;
        shift @remaining if @remaining && defined($remaining[0]) && $remaining[0] eq 'rbp';
        for my $r (@remaining) {
            my $reg_num = $SEH_REG{$r};
            my $size    = ( $reg_num < 8 ) ? 1 : 2;
            $offset += $size;
            push @push_info, { reg_num => $reg_num, offset => $offset };
        }

        # sub rsp, imm32 (7 bytes)
        my $alloc_offset  = $offset + 7;
        my $prologue_size = $alloc_offset;

        # Emit unwind codes in reverse order (last executed first)
        # 1. UWOP_ALLOC_LARGE (op=1, info=0) - 2 slots
        $codes .= pack( 'CC', $prologue_size, ( 0 << 4 ) | 1 ) . pack( 'S<', $scaled );

        # 2. UWOP_PUSH_NONVOL (op=0) for other registers
        for my $pi ( reverse @push_info ) {
            $codes .= pack( 'CC', $pi->{offset}, ( $pi->{reg_num} << 4 ) | 0 );
        }

        # Count how many 16-bit code words we have
        my $num_codes = length($codes) / 2;

        # Pad to DWORD alignment
        my $pad = ( 4 - ( length($codes) % 4 ) ) % 4;
        $codes .= "\0" x $pad;

        # Header: Ver=1, PrologueSize, NumCodes, FrameReg=0, FrameOffset=0
        # FrameReg is configured as 0 (no frame pointer register configured for SEH),
        # so Windows unwinds exclusively using stack offsets and registers pushed.
        my $hdr = pack( 'C C C C', 1, $prologue_size, $num_codes, 0 );
        return $hdr . $codes;
    }

    # In Brocken::Format::PE
    method _build_pdata ( $text_rva, $xdata_rva ) {
        my $data = '';

        # Use the ranges passed from the compiler
        for my $fn ( sort { $a->{start} <=> $b->{start} } @{ $self->func_ranges } ) {
            $data .= pack( 'L< L< L<', $text_rva + $fn->{start}, $text_rva + ( $fn->{end} // ( $fn->{start} + 1 ) ), $xdata_rva );
        }
        return $data;
    }

    method _build_edata_raw( $base_rva, $filename ) {
        my @exports = @{ $self->exported_funcs // [] };
        warn "PE: _build_edata_raw - exports found: " . scalar(@exports) . "\n" if $ENV{BROCKEN_JIT_DEBUG};
        my $num_exports = scalar @exports;
        return ( "\0" x 2048 ) if $num_exports == 0;
        my $eat_off       = 40;
        my $npt_off       = $eat_off + ( 4 * $num_exports );
        my $ot_off        = $npt_off + ( 4 * $num_exports ); # Fixed calculation offset
        my $name_data_off = $ot_off + ( 2 * $num_exports );
        my $edat          = pack(
            'L< L< S< S< L< L< L< L< L< L< L<',
            0, time(),       0, 0, $base_rva + $name_data_off,
            1, $num_exports, $num_exports,
            $base_rva + $eat_off,
            $base_rva + $npt_off,
            $base_rva + $ot_off
        );
        my $eat          = '';
        my $npt          = '';
        my $ot           = '';
        my $name_data    = basename($filename) . "\0";
        my $name_ptr_off = length($name_data);           # Running offset to current name

        for my $i ( 0 .. $#exports ) {
            my $name         = $exports[$i];
            my $target_label = "E_$name";                        # Use the autoboxing thunk not the internal M_ function
            my $offset       = $self->labels->{$target_label};
            if ( !defined $offset ) {
                warn "PE: Export label $target_label NOT FOUND in map!\n" if $ENV{BROCKEN_JIT_DEBUG};
                $offset = 0;
            }
            my $rva = $self->rva_for('.text') + $offset;
            warn "PE: Export $name -> RVA " . sprintf( "0x%X", $rva ) . "\n" if $ENV{BROCKEN_JIT_DEBUG};
            $eat .= pack( 'L<', $rva );
            $npt .= pack( 'L<', $base_rva + $name_data_off + $name_ptr_off );
            $ot  .= pack( 'S<', $i );
            $name_data .= $name . "\0";
            $name_ptr_off += length($name) + 1;
        }
        my $block   = $edat . $eat . $npt . $ot . $name_data;
        my $pad_len = 2048 - length($block);
        $pad_len = 0 if $pad_len < 0;
        return $block . ( "\0" x $pad_len );
    }
}
1;
__END__

=pod

=head1 NAME

Brocken::Format::PE - Windows PE+ (64-bit) binary format writer

=head1 SYNOPSIS

  my $pe = Brocken::Format::PE->new(type => 'executable');
  $pe->write_bin("out.exe", $code, $data, "x64", "win64");

=head1 DESCRIPTION

Generates 64-bit Windows Portable Executable (PE32+) binaries.  Supports: - Executables and DLLs (shared libraries). -
Import Address Table (IAT) for kernel32.dll functions. - Export Directory (.edata) for DLL exports. - Structured
Exception Handling (SEH) with .pdata and .xdata sections. - DWARF debug sections.

=head1 METHODS

=head2 import_rva($name)

Returns the RVA of the IAT entry for a given kernel32 function (e.g., 'ExitProcess').

=head2 image_base()

Returns the default load address 0x140000000.

=head2 write_bin($filename, $text, $data, $arch, $os, $type)

Constructs and writes the PE file: 1. Calculates layout and SEH data. 2. Writes MS-DOS stub and PE signature. 3. Writes
COFF File Header and Optional Header (PE32+). 4. Writes Section Headers. 5. Appends all section payloads (.text, .data,
.idata, .edata, .pdata, .xdata, .debug_*).

=cut
