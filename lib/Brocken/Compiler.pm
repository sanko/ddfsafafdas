package Brocken::Compiler {
    use v5.40;
    use utf8;
    use feature 'class';
    no warnings 'portable', 'experimental::class';
    use Brocken::Emit;
    use Brocken::Format;

    class Brocken::Compiler {
        field $arch   : reader : param = undef;
        field $os     : reader : param = undef;
        field $as     : reader;
        field $format : reader;
        field $local_ptr = 0;
        field $target : reader;
        ADJUST {
            my $d_os = 'linux';
            $d_os = 'win64' if $^O eq 'MSWin32';
            $d_os = 'macos' if $^O eq 'darwin';
            my $d_arch = 'x64';
            if ( $^O eq 'MSWin32' ) { $d_arch = ( ( $ENV{PROCESSOR_ARCHITECTURE} // '' ) =~ /ARM64/i ) ? 'arm64' : 'x64'; }
            else                    { my $m = `uname -m` // 'x86_64'; $d_arch = 'arm64' if $m =~ /aarch64|arm64|armv8/i; }
            $os   //= $d_os;
            $arch //= $d_arch;
            $as = $arch eq 'arm64' ? Brocken::Emit::ARM64->new() : Brocken::Emit::X64->new();
            if    ( $os eq 'win64' ) { $format = Brocken::Format::PE->new() }
            elsif ( $os eq 'macos' ) { $format = Brocken::Format::MachO->new() }
            else                     { $format = Brocken::Format::ELF->new() }

            if ( $arch eq 'x64' ) {
                require Brocken::Target::X64;
                $target = Brocken::Target::X64->new( os => $os, arch => $arch );
            }
        }

        # --- ABI DESCRIPTORS ---
        # The list of registers that MUST be preserved across calls and switches
        method preserved_regs() {
            if ( $arch eq 'x64' ) {
                return $os eq 'win64' ? [qw(rbp rbx rdi rsi r12 r13 r14 r15)] : [qw(rbp rbx r12 r13 r14 r15)];
            }
            return [qw(x19 x20 x21 x22 x23 x24 x25 x26 x27 x28 x29 x30)];
        }

        method context_size() {
            return scalar( @{ $self->preserved_regs() } ) * 8;
        }

        # Calculates where a register is located within the pushed stack block
        method context_offset($reg_name) {
            my $list = $self->preserved_regs();
            for my $i ( 0 .. $#$list ) {
                if ( $list->[$i] eq $reg_name ) {

                    # Push order: A, B, C. Stack: [C, B, A]
                    # Offset of A is 16, offset of C is 0.
                    return ( scalar(@$list) - 1 - $i ) * 8;
                }
            }
            die "Register $reg_name is not preserved in this ABI";
        }

        # Automatic alignment: (PushedRegs + ShadowSpace + Locals + Padding) % 16 == 0
        method frame_local_size() {
            my $pushed_count = scalar( @{ $self->preserved_regs() } );
            my $shadow       = ( $os eq 'win64' ) ? 32 : 0;
            my $locals       = 1024;

            # RSP starts at 16n + 8. Pushing N registers changes it.
            # We add padding so that after 'sub rsp, frame_local_size', RSP is 16-aligned.
            my $bytes_pushed = $pushed_count * 8;
            my $needed       = ( $bytes_pushed + 8 + $shadow + $locals );
            my $padding      = ( 16 - ( $needed % 16 ) ) % 16;
            return $locals + $padding + $shadow;
        }
        method text_rva ()        { $format->rva_for('.text') }
        method data_rva ()        { $format->rva_for('.data') }
        method idata_rva ()       { $format->rva_for('.idata') }
        method import_rva ($name) { $format->import_rva($name) }
        method local_ptr ()       { return $local_ptr; }
        method set_local_ptr ($v) { $local_ptr = $v; }
        method reset_locals ()    { $local_ptr = 0; }

        method alloc_local_slot () {
            $local_ptr += 8;
            die 'Stack Overflow' if $local_ptr > 1024;
            return $local_ptr;
        }

        method iso_offset ($name) {
            state $ISO = { heap_ptr => 0, heap_limit => 8, state_ptr => 16, current_fcb => 24, fiber_head => 32, };
            return $ISO->{$name} // die "Unknown Isolate offset: $name";
        }

        method fcb_offset ($name) {
            state $FCB = { sp => 0, stack_base => 8, stack_limit => 16, shadow_base => 24, shadow_ptr => 32, caller => 40, next => 48 };
            return $FCB->{$name} // die "Unknown FCB offset: $name";
        }

        method cc ($name) {
            return { eq => 0, ne => 1, lt => 0xB, gt => 0xC, z => 0, nz => 1 }->{$name} if $arch eq 'arm64';
            return { eq => 4, ne => 5, lt => 0xC, gt => 0xF, z => 4, nz => 5 }->{$name};
        }

        method exit_reg ($reg) {
            my $r_name = $reg // ( $arch eq 'arm64' ? 'xzr' : 'rax' );
            if ( $os eq 'linux' || $os eq 'macos' ) {
                if ( $arch eq 'arm64' ) {
                    $as->mov_imm( $os eq 'macos' ? 'x16' : 'x8', $os eq 'macos' ? 0x2000001 : 93 );
                    $as->mov_reg( 'x0', $r_name ) if $r_name ne 'x0';
                    $as->syscall( $os eq 'macos' );
                }
                else {
                    $as->mov_imm( 'rax', $os eq 'macos' ? 0x2000001 : 60 );
                    $as->mov_reg( 'rdi', $r_name ) if $r_name ne 'rdi';
                    $as->syscall();
                }
            }
            else {
                if ( $arch eq 'arm64' ) {
                    $as->mov_reg( 'x0', $r_name ) if $r_name ne 'x0';
                    $as->call_rva( $self->import_rva('ExitProcess'), $self->text_rva );
                }
                else { $as->mov_reg( 'rcx', $r_name ) if $r_name ne 'rcx'; $as->call_rva( $self->import_rva('ExitProcess'), $self->text_rva ); }
            }
        }
    }
}
1;
