package Pulse::Compiler {
    use v5.40;
    use utf8;
    use feature 'class';
    no warnings 'portable', 'experimental::class';
    #
    class Pulse::Compiler {
        field $arch   : reader : param = undef;
        field $os     : reader : param = undef;
        field $as     : reader;
        field $format : reader;
        ADJUST {
            my $d_os = 'linux';
            $d_os = 'win64' if $^O eq 'MSWin32';
            $d_os = 'macos' if $^O eq 'darwin';
            my $d_arch = 'x64';
            if ( $^O eq 'MSWin32' ) { $d_arch = ( ( $ENV{PROCESSOR_ARCHITECTURE} // '' ) =~ /ARM64/i ) ? 'arm64' : 'x64'; }
            else                    { my $m = `uname -m` // 'x86_64'; $d_arch = 'arm64' if $m =~ /aarch64|arm64|armv8/i; }
            $os   //= $d_os;
            $arch //= $d_arch;
            $as = $arch eq 'arm64' ? Pulse::Emit::ARM64->new() : Pulse::Emit::X64->new();
            if    ( $os eq 'win64' ) { $format = Pulse::Format::PE->new() }
            elsif ( $os eq 'macos' ) { $format = Pulse::Format::MachO->new() }
            else                     { $format = Pulse::Format::ELF->new() }
        }

        method text_rva ()  { $format->rva_for( '.text',  $arch, $os ) }
        method data_rva ()  { $format->rva_for( '.data',  $arch, $os ) }
        method idata_rva () { $format->rva_for( '.idata', $arch, $os ) }

        method import_rva ($name) { $format->import_rva($name) }

        method iso_offset ($name) {
            state $ISO = {
                heap_ptr    => 0,
                heap_limit  => 8,
                state_ptr   => 16,
                current_fcb => 24,
            };
            die "Unknown Isolate offset: $name" unless exists $ISO->{$name};
            return $ISO->{$name};
        }

        method fcb_offset ($name) {
            state $FCB = {
                sp          => 0,
                stack_base  => 8,
                shadow_base => 16,
                shadow_ptr  => 24,
                caller      => 32,
            };
            die "Unknown FCB offset: $name" unless exists $FCB->{$name};
            return $FCB->{$name};
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
                if   ( $arch eq 'arm64' ) { $as->mov_reg( 'x0',  $r_name ) if $r_name ne 'x0';  $as->call_rva( $self->import_rva('ExitProcess'), $self->text_rva ); }
                else                      { $as->mov_reg( 'rcx', $r_name ) if $r_name ne 'rcx'; $as->call_rva( $self->import_rva('ExitProcess'), $self->text_rva ); }
            }
        }
    }

    class Brocken::Compiler::DataSegment {
        use Encode qw(encode);
        field $raw_data = '';
        field %string_offsets;

        method add_string($str) {
            return $string_offsets{$str} if exists $string_offsets{$str};
            my $offset     = length($raw_data);
            my $utf8_bytes = encode( 'UTF-8', $str );
            my $byte_len   = length($utf8_bytes);
            $raw_data .= pack( 'Q< Q< Q<', $byte_len, length($str), ( $str =~ /^[\x00-\x7f]*$/ ? 1 : 0 ) );
            $raw_data .= $utf8_bytes;
            $raw_data .= "\0" x ( ( 8 - ( ( 24 + $byte_len ) % 8 ) ) % 8 );
            return $string_offsets{$str} = $offset;
        }
        method get_raw_data() { return $raw_data; }
    }
}
1;
