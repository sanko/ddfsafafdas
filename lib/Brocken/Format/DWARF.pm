package Brocken::Format::DWARF {
    use v5.40;
    use utf8;
    use feature 'class';
    no warnings 'experimental::class';

    class Brocken::Format::DWARF {
        field $source_locs    : param : reader;
        field $text_base      : param : reader;
        field $source_file    : param : reader = 'source.brocken';
        field $func_ranges    : param : reader = [];
        field $context_size   : param : reader = 64;
        field $class_info     : param : reader = {};
        field $debug          : param : reader = 0;
        field $eh_frame_base  : param : reader = 0;
        field $arch           : param : reader = 'x64';
        field $preserved_regs : param : reader = [];
        field @pubnames;
        our %DWARF_REG = (
            rax => 0,
            rdx => 1,
            rcx => 2,
            rbx => 3,
            rsi => 4,
            rdi => 5,
            rbp => 6,
            rsp => 7,
            r8  => 8,
            r9  => 9,
            r10 => 10,
            r11 => 11,
            r12 => 12,
            r13 => 13,
            r14 => 14,
            r15 => 15,
        );

        method build_all () {
            my $info     = $self->build_debug_info;
            my $sections = { '.debug_line' => $self->build_debug_line, '.debug_info' => $info, '.debug_abbrev' => $self->build_debug_abbrev, };
            if (@$func_ranges) {
                $sections->{'.debug_frame'}    = $self->build_debug_frame;
                $sections->{'.debug_aranges'}  = $self->build_debug_aranges;
                $sections->{'.debug_pubnames'} = $self->build_debug_pubnames( length($info) );
                $sections->{'.eh_frame'}       = $self->build_eh_frame if $self->eh_frame_base;
            }
            return $sections;
        }

        method build_debug_line () {
            my @entries   = sort { $a->{offset} <=> $b->{offset} } @$source_locs;
            my $program   = '';
            my $prev_line = 1;
            my $prev_addr = $text_base;
            for my $e (@entries) {
                my $addr = $text_base + $e->{offset};
                my $line = $e->{line};

                # Set Address
                $program .= "\x00" . $self->_uleb(9) . "\x02" . pack( 'Q<', $addr );

                # Advance Line
                $program .= "\x03" . $self->_sleb( $line - $prev_line );

                # Copy row
                $program .= "\x01";
                $prev_line = $line;
            }

            # End of sequence
            my $max_offset = 0;
            for my $fn (@$func_ranges) { $max_offset = $fn->{end} if ( $fn->{end} // 0 ) > $max_offset; }
            $program .= "\x00" . $self->_uleb(9) . "\x02" . pack( 'Q<', $text_base + $max_offset );
            $program .= "\x00" . $self->_uleb(1) . "\x01";
            my $prologue = pack( 'C', 1 ) . pack( 'C', 1 ) . pack( 'c', -5 ) . pack( 'C', 14 ) . pack( 'C', 13 );
            $prologue .= pack( 'C*', 0, 1, 1, 1, 1, 0, 0, 0, 1, 0, 0, 1 );
            $prologue .= "\x00";                                                                     # Directory table
            $prologue .= "$source_file\x00" . $self->_uleb(0) . $self->_uleb(0) . $self->_uleb(0);
            $prologue .= "\x00";
            my $full_len = 2 + 4 + length($prologue) + length($program);
            my $header   = pack( 'L<', $full_len );
            $header .= pack( 'S<', 2 );
            $header .= pack( 'L<', length($prologue) );
            return $header . $prologue . $program;
        }

        method build_debug_abbrev () {
            my $abbrev = '';

            # Abbrev 1: DW_TAG_compile_unit
            $abbrev .= $self->_uleb(1) . $self->_uleb(0x11) . $self->_uleb(1);
            $abbrev .= $self->_uleb(0x10) . $self->_uleb(0x06);                  # DW_AT_stmt_list -> data4
            $abbrev .= $self->_uleb(0x03) . $self->_uleb(0x08);                  # DW_AT_name -> string
            $abbrev .= $self->_uleb(0x13) . $self->_uleb(0x0B);                  # DW_AT_language -> data1
            $abbrev .= $self->_uleb(0x11) . $self->_uleb(0x01);                  # DW_AT_low_pc -> addr
            $abbrev .= $self->_uleb(0x12) . $self->_uleb(0x01);                  # DW_AT_high_pc -> addr
            $abbrev .= pack( 'CC', 0, 0 );

            # Abbrev 2: DW_TAG_base_type
            $abbrev .= $self->_uleb(2) . $self->_uleb(0x24) . $self->_uleb(0);
            $abbrev .= $self->_uleb(0x03) . $self->_uleb(0x08);                  # DW_AT_name -> string
            $abbrev .= $self->_uleb(0x0B) . $self->_uleb(0x0B);                  # DW_AT_byte_size -> data1
            $abbrev .= $self->_uleb(0x3E) . $self->_uleb(0x0B);                  # DW_AT_encoding -> data1
            $abbrev .= pack( 'CC', 0, 0 );

            # Abbrev 3: DW_TAG_subprogram
            $abbrev .= $self->_uleb(3) . $self->_uleb(0x2E) . $self->_uleb(1);
            $abbrev .= $self->_uleb(0x03) . $self->_uleb(0x08);                  # DW_AT_name
            $abbrev .= $self->_uleb(0x11) . $self->_uleb(0x01);                  # low_pc
            $abbrev .= $self->_uleb(0x12) . $self->_uleb(0x01);                  # high_pc
            $abbrev .= $self->_uleb(0x40) . $self->_uleb(0x18);                  # frame_base -> exprloc
            $abbrev .= pack( 'CC', 0, 0 );

            # Abbrev 4: DW_TAG_formal_parameter / Abbrev 5: DW_TAG_variable
            for ( 4 .. 5 ) {
                $abbrev .= $self->_uleb($_) . $self->_uleb( $_ == 4 ? 0x05 : 0x34 ) . $self->_uleb(0);
                $abbrev .= $self->_uleb(0x03) . $self->_uleb(0x08);                                      # name
                $abbrev .= $self->_uleb(0x02) . $self->_uleb(0x18);                                      # location
                $abbrev .= $self->_uleb(0x49) . $self->_uleb(0x13);                                      # type -> ref4
                $abbrev .= pack( 'CC', 0, 0 );
            }
            $abbrev .= "\x00";
            return $abbrev;
        }

        method build_debug_info () {
            my $max_pc = 0;
            for my $fn (@$func_ranges) { $max_pc = $fn->{end} if ( $fn->{end} // 0 ) > $max_pc; }
            my $cu_body = '';
            $cu_body .= $self->_uleb(1);                       # DW_TAG_compile_unit
            $cu_body .= pack( 'L<', 0 );                       # stmt_list
            $cu_body .= "$source_file\0";
            $cu_body .= pack( 'C',  12 );                      # language (C99)
            $cu_body .= pack( 'Q<', $text_base );              # low_pc
            $cu_body .= pack( 'Q<', $text_base + $max_pc );    # high_pc
            my $CU_HEADER_SIZE = 11;
            my $type_off       = {};

            for my $t ( [ 'Int', 5 ], [ 'Bool', 2 ], [ 'String', 1 ], [ 'Any', 1 ], [ 'ptr', 1 ], [ 'Array', 1 ] ) {
                $type_off->{ $t->[0] } = $CU_HEADER_SIZE + length($cu_body);
                $cu_body .= $self->_uleb(2) . "$t->[0]\0" . pack( 'CC', 8, $t->[1] );
            }
            for my $fn ( sort { $a->{start} <=> $b->{start} } @$func_ranges ) {
                my $die_off = $CU_HEADER_SIZE + length($cu_body);
                push @pubnames, { offset => $die_off, name => ( $fn->{name} =~ s/^M_//r ) };
                $cu_body .= $self->_uleb(3);    # DW_TAG_subprogram
                $cu_body .= "$fn->{name}\0";
                $cu_body .= pack( 'Q<', $text_base + $fn->{start} );
                $cu_body .= pack( 'Q<', $text_base + ( $fn->{end} // $fn->{start} ) );

                # frame_base (RBP relative)
                my $fb = pack( 'C', 0x70 + ( $arch eq 'arm64' ? 29 : 6 ) ) . "\x00";
                $cu_body .= $self->_uleb( length($fb) ) . $fb;
                for my $v ( @{ $fn->{params} // [] }, @{ $fn->{locals} // [] } ) {
                    $cu_body .= $self->_uleb( exists $v->{slot} ? 5 : 4 );
                    ( my $n = $v->{name} ) =~ s/^\$//;
                    $cu_body .= "$n\0";
                    my $loc = "\x91" . $self->_sleb( -$v->{slot} );
                    $cu_body .= $self->_uleb( length($loc) ) . $loc;
                    $cu_body .= pack( 'L<', $type_off->{ $v->{type} } // $type_off->{Any} );
                }
                $cu_body .= "\x00";    # end subprogram
            }
            $cu_body .= "\x00";        # end CU
            return pack( 'L< S< L< C', length($cu_body) + 7, 2, 0, 8 ) . $cu_body;
        }

        method build_debug_aranges () {
            my $max_pc = 0;
            for my $fn (@$func_ranges) { $max_pc = $fn->{end} if ( $fn->{end} // 0 ) > $max_pc; }
            my $body = pack( 'Q< Q<', $text_base, $max_pc );
            $body .= pack( 'Q< Q<', 0, 0 );
            my $header = pack( 'S< L< C C', 2, 0, 8, 0 );

            # Padding to 16-byte boundary
            my $pad = ( 16 - ( ( length($header) + 4 ) % 16 ) ) % 16;
            return pack( 'L<', length($header) + $pad + length($body) ) . $header . ( "\0" x $pad ) . $body;
        }

        method build_debug_pubnames ( $info_len = 0 ) {
            my $body = '';
            for my $pn (@pubnames) { $body .= pack( 'L<', $pn->{offset} ) . "$pn->{name}\0"; }
            $body .= pack( 'L<', 0 );
            return pack( 'L< S< L< L<', length($body) + 10, 2, 0, $info_len ) . $body;
        }

        method _uleb ($v) {
            my $out = '';
            do {
                my $byte = $v & 0x7F;
                $v >>= 7;
                $byte |= 0x80 if $v;
                $out .= pack( 'C', $byte );
            } while ($v);
            return $out;
        }

        method _sleb ($v) {
            require POSIX;
            my $out = '';
            while (1) {
                my $byte = $v & 0x7f;
                $v = POSIX::floor( $v / 128 );
                if ( ( $v == 0 && !( $byte & 0x40 ) ) || ( $v == -1 && ( $byte & 0x40 ) ) ) {
                    $out .= pack( 'C', $byte );
                    last;
                }
                $out .= pack( 'C', $byte | 0x80 );
            }
            return $out;
        }

        method build_debug_frame () {

            # Basic CIE
            my $cie_body = pack( 'C', 3 ) . "\0" . $self->_uleb(1) . $self->_sleb(-8);
            $cie_body .= ( $arch eq 'arm64'                      ? pack( 'C', 30 ) : pack( 'C', 16 ) );        # Return reg
            $cie_body .= "\x0C" . $self->_uleb( $arch eq 'arm64' ? 31              : 7 ) . $self->_uleb(8);    # def_cfa

            # Tell DWARF where the return address is saved (offset 1 * -8)
            if ( $arch eq 'x64' ) {
                $cie_body .= pack( 'C', 0x80 | 16 ) . $self->_uleb(1);
            }
            my $cie_pad = ( 8 - ( ( length($cie_body) + 8 ) % 8 ) ) % 8;
            $cie_body .= "\0" x $cie_pad;
            my $data = pack( 'L<', length($cie_body) + 4 ) . pack( 'L<', 0xFFFFFFFF ) . $cie_body;
            for my $fn (@$func_ranges) {
                my $instr           = "\x0C" . $self->_uleb( $arch eq 'arm64' ? 29 : 6 ) . $self->_uleb( $context_size + 8 );
                my $offset_from_cfa = -16;
                for my $r (@$preserved_regs) {
                    my $reg_num      = $arch eq 'arm64' ? 0 : $DWARF_REG{$r};
                    my $factored_off = $offset_from_cfa / -8;
                    $instr .= pack( 'C', 0x80 | $reg_num ) . $self->_uleb($factored_off);
                    $offset_from_cfa -= 8;
                }
                my $fde_body = pack( 'Q< Q<', $text_base + $fn->{start}, $fn->{end} - $fn->{start} ) . $instr;
                my $fde_pad  = ( 8 - ( ( length($fde_body) + 8 ) % 8 ) ) % 8;
                $fde_body .= "\0" x $fde_pad;
                $data     .= pack( 'L<', length($fde_body) + 4 ) . pack( 'L<', 0 ) . $fde_body;
            }
            return $data;
        }
        method build_eh_frame () { return ''; }    # Placeholder
    }
}
1;
