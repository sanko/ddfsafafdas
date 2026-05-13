package Brocken::Compiler {
    use v5.40;
    use utf8;
    use feature 'class';
    no warnings 'portable', 'experimental::class';

    class Brocken::Compiler {

        # Input Parameters
        field $arch  : param : reader = undef;
        field $os    : param : reader = undef;
        field $debug : param : reader = 0;

        # Plugged components
        field $target   : reader;    # CPU Logic (e.g. Target::X64)
        field $platform : reader;    # OS Logic (e.g. Platform::Windows)
        field $as       : reader;    # Instruction Emitter (e.g. Emit::X64)
        field $format   : reader;    # Binary Formatter (e.g. Format::PE)

        # State management
        field $local_ptr = 0;
        field @source_locs;
        field @func_ranges;
        field %debug_func_params;
        field %debug_func_locals;
        ADJUST {
            # 1. Platform Detection
            my $detected_os = $^O eq 'MSWin32' ? 'win64' : ( $^O eq 'darwin' ? 'macos' : 'linux' );
            $os //= $detected_os;

            # 2. Architecture Detection
            my $detected_arch = 'x64';
            if ( $^O eq 'MSWin32' ) {
                $detected_arch = ( ( $ENV{PROCESSOR_ARCHITECTURE} // '' ) =~ /ARM64/i ) ? 'arm64' : 'x64';
            }
            else {
                my $m = `uname -m` // 'x86_64';
                $detected_arch = 'arm64' if $m =~ /aarch64|arm64|armv8/i;
            }
            $arch //= $detected_arch;

            # 3. Load Platform & Formatter
            if ( $os eq 'win64' ) {
                require Brocken::Platform::Windows;
                require Brocken::Format::PE;
                $platform = Brocken::Platform::Windows->new( os => $os );
                $format   = Brocken::Format::PE->new();
            }
            elsif ( $os eq 'linux' ) {
                require Brocken::Platform::Linux;
                require Brocken::Format::ELF;
                $platform = Brocken::Platform::Linux->new( os => $os );
                $format   = Brocken::Format::ELF->new();
            }
            elsif ( $os eq 'macos' ) {
                require Brocken::Platform::Darwin;
                require Brocken::Format::MachO;
                $platform = Brocken::Platform::Darwin->new( os => $os );
                $format   = Brocken::Format::MachO->new();
            }
            else {
                die "Unsupported OS: $os";
            }

            # 4. Load Target & Emitter
            if ( $arch eq 'x64' ) {
                require Brocken::Target::X64;
                require Brocken::Target::X64::Emit;
                $target = Brocken::Target::X64->new( os => $os, arch => $arch );
                $as     = Brocken::Target::X64::Emit->new();
            }
            elsif ( $arch eq 'arm64' ) {
                require Brocken::Target::ARM64;
                require Brocken::Target::ARM64::Emit;
                $target = Brocken::Target::ARM64->new( os => $os, arch => $arch );
                $as     = Brocken::Target::ARM64::Emit->new();
            }
            else {
                die "Unsupported Architecture: $arch";
            }
        }

        # --- ABI Proxy Methods ---
        # These delegate to Target/Platform to provide data for Lowering/Codegen
        method preserved_regs() {

            # X64 preserved registers depend on OS (Win has more)
            if ( $arch eq 'x64' ) {
                return $os eq 'win64' ? [qw(rbp rbx rdi rsi r12 r13 r14 r15)] : [qw(rbp rbx r12 r13 r14 r15)];
            }

            # Fallback for ARM64
            return [qw(x19 x20 x21 x22 x23 x24 x25 x26 x27 x28 x29 x30)];
        }

        method context_size() {
            my $stride = ( $arch eq 'arm64' ) ? 16 : 8;
            return scalar( @{ $self->preserved_regs() } ) * $stride;
        }

        method context_offset($reg_name) {
            my $list   = $self->preserved_regs();
            my $stride = ( $arch eq 'arm64' ) ? 16 : 8;
            for my $i ( 0 .. $#$list ) {

                # Stack order is usually reverse of push order
                if ( $list->[$i] eq $reg_name ) {
                    return ( scalar(@$list) - 1 - $i ) * $stride;
                }
            }
            die "Register $reg_name is not preserved in this ABI";
        }

        method frame_local_size() {
            my $locals      = 1024;
            my $ctx         = $self->context_size();
            my $shadow      = $platform->shadow_space();
            my $target_size = $locals + $shadow;

            # RSP is 8 mod 16 on entry.
            # After pushing ctx bytes, RSP is (8 - ctx) mod 16.
            # We subtract size, so RSP becomes (8 - ctx - size) mod 16.
            # We want (8 - ctx - size) ≡ 0 mod 16, which means size ≡ 8 - ctx mod 16.
            my $rem = ( 8 - $ctx ) % 16;
            $rem += 16 if $rem < 0;
            my $align_padding = ( $rem - ( $target_size % 16 ) ) % 16;
            $align_padding += 16 if $align_padding < 0;
            my $size = $target_size + $align_padding;

            # warn "DEBUG frame_local_size: ctx=$ctx shadow=$shadow locals=$locals target=$target_size rem=$rem padding=$align_padding -> size=$size";
            return $size;
        }

        # --- Format RVAs ---
        method text_rva ()        { $format->rva_for('.text') }
        method data_rva ()        { $format->rva_for('.data') }
        method import_rva ($name) { $format->import_rva($name) }

        # --- Debug Info ---
        method source_locs () { return @source_locs; }

        method push_source_loc ( $offset, $line, $col ) {
            push @source_locs, { offset => $offset, line => $line, col => $col };
        }

        # --- Function Ranges (for DWARF .debug_frame) ---
        method func_ranges ()       { return @func_ranges; }
        method push_func_range ($r) { push @func_ranges, $r; }
        method clear_func_ranges () { @func_ranges = (); }
        method set_debug_func_params ( $name, $params ) { $debug_func_params{$name} = $params; }
        method get_debug_func_params ($name)            { return $debug_func_params{$name} // []; }
        method set_debug_func_locals ( $name, $locals ) { $debug_func_locals{$name} = $locals; }
        method get_debug_func_locals ($name)            { return $debug_func_locals{$name} // []; }

        method close_last_func_range ($end_offset) {
            if ( @func_ranges && !defined $func_ranges[-1]{end} ) {
                $func_ranges[-1]{end} = $end_offset;
            }
        }

        # --- Stack Management ---
        method local_ptr ()       { return $local_ptr; }
        method set_local_ptr ($v) { $local_ptr = $v; }
        method reset_locals ()    { $local_ptr = 0; }

        method dwarf_local_offset ($slot) {
            return -( $slot + $self->context_size + 8 );
        }

        method alloc_local_slot () {
            $local_ptr += 8;
            die 'Stack Overflow: Local area exceeded 1024 bytes' if $local_ptr > 1024;
            return $local_ptr;
        }

        # --- Brocken Runtime Layouts ---
        method iso_offset ($name) {
            state $ISO = {
                heap_ptr          => 0,
                heap_limit        => 8,
                state_ptr         => 16,
                current_fcb       => 24,
                fiber_head        => 32,
                heap_base         => 40,
                block_cursor      => 48,
                block_limit       => 56,
                free_blocks       => 64,
                recyclable_blocks => 72,
                gc_cycle          => 80,
                heap_min          => 88,
                heap_max          => 96
            };
            return $ISO->{$name} // die "Unknown Isolate offset: $name";
        }

        method fcb_offset ($name) {
            state $FCB
                = { sp => 0, stack_base => 8, stack_limit => 16, shadow_base => 24, shadow_ptr => 32, caller => 40, next => 48, wait_handle => 56 };
            return $FCB->{$name} // die "Unknown FCB offset: $name";
        }

        # --- Condition Codes ---
        method cc ($name) {
            if ( $arch eq 'arm64' ) {
                return { eq => 0, ne => 1, lt => 0xB, gt => 0xC, ge => 0xA, le => 0xD, z => 0, nz => 1 }->{$name};
            }

            # X64
            return { eq => 4, ne => 5, lt => 0xC, gt => 0xF, z => 4, nz => 5 }->{$name};
        }
    }
}
1;
__END__

=pod

=head1 NAME

Brocken::Compiler - Platform detection and ABI driver

=head1 DESCRIPTION

Detects the host OS and CPU architecture at construction time (ADJUST), then loads the appropriate Platform, Format,
Target, and Emitter modules.

Provides ABI proxy methods used by Lowering and Codegen: preserved register lists, frame layout, Isolate and Fiber
control block offsets, condition code mappings.

=head1 CONSTRUCTOR

    my $p = Brocken::Compiler->new(
        debug => 2,        # optional, default 0
        arch => 'x64',     # optional, auto-detected
        os   => 'linux'    # optional, auto-detected
    );

=head2 Parameters

=over

=item debug (optional, default 0)

Controls emission of debug information sections in the output binary.

=over

=item B<0> - No debug sections. Lean binary, no source mapping.

=item B<1> - Emit all DWARF debug sections (C<.debug_line>, C<.debug_info>, C<.debug_abbrev>, C<.debug_frame>, C<.debug_aranges>, C<.debug_pubnames>). On win64, also emit SEH C<.pdata> / C<.xdata> unwind tables. On ELF, also emit C<.eh_frame> section. Launch GDB after compilation.

=item B<2> - Same as level 1, plus hex dumps of C<.debug_info>, C<.debug_abbrev>, C<.debug_aranges>, C<.debug_pubnames>.

=item B<4> - Include class/struct type DIEs (C<DW_TAG_structure_type>, C<DW_TAG_member>) in C<.debug_info>.

=back

See L<Brocken::Format::DWARF> and L<docs/debugging.md> for details on each debug section's format and purpose.

=item arch (optional, auto-detected)

Target CPU architecture. Currently only C<'x64'> is supported. C<'arm64'> detection is implemented but the codegen
backend is not yet wired in.

=item os (optional, auto-detected)

Target operating system. One of C<'win64'>, C<'linux'>, or C<'macos'>. C<'macos'> is detected but dies with a "support
pending" message.

=back

=head1 METHODS

=head2 preserved_regs

Returns callee-saved register names for the current OS/arch.

=head2 frame_local_size

Total frame size including context save, return address, shadow space, and local variables, aligned to 16 bytes.

=head2 iso_offset($name) / fcb_offset($name)

Field offsets within the Isolate control block and Fiber Control Block.

=head2 cc($name)

Condition code mapping for branch instructions.

=cut
