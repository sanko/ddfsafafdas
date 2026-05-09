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

                # require Brocken::Platform::Darwin;
                # require Brocken::Format::MachO;
                die "Platform MacOS support pending refactor";
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

                # require Brocken::Target::ARM64;
                require Brocken::Target::ARM64::Emit;
                die "Target ARM64 support pending refactor";
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
            return scalar( @{ $self->preserved_regs() } ) * 8;
        }

        method context_offset($reg_name) {
            my $list = $self->preserved_regs();
            for my $i ( 0 .. $#$list ) {

                # Stack order is usually reverse of push order
                if ( $list->[$i] eq $reg_name ) {
                    return ( scalar(@$list) - 1 - $i ) * 8;
                }
            }
            die "Register $reg_name is not preserved in this ABI";
        }

        method frame_local_size() {

            # (Context + RetAddr + Shadow + Locals) aligned to 16
            my $locals  = 1024;
            my $needed  = ( $self->context_size() + 8 + $platform->shadow_space() + $locals );
            my $padding = ( 16 - ( $needed % 16 ) ) % 16;
            return $locals + $padding + $platform->shadow_space();
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

        # --- Stack Management ---
        method local_ptr ()       { return $local_ptr; }
        method set_local_ptr ($v) { $local_ptr = $v; }
        method reset_locals ()    { $local_ptr = 0; }

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
                gc_cycle          => 80
            };
            return $ISO->{$name} // die "Unknown Isolate offset: $name";
        }

        method fcb_offset ($name) {
            state $FCB = { sp => 0, stack_base => 8, stack_limit => 16, shadow_base => 24, shadow_ptr => 32, caller => 40, next => 48 };
            return $FCB->{$name} // die "Unknown FCB offset: $name";
        }

        # --- Condition Codes ---
        method cc ($name) {
            if ( $arch eq 'arm64' ) {
                return { eq => 0, ne => 1, lt => 0xB, gt => 0xC, z => 0, nz => 1 }->{$name};
            }

            # X64
            return { eq => 4, ne => 5, lt => 0xC, gt => 0xF, z => 4, nz => 5 }->{$name};
        }
    }
}
1;
