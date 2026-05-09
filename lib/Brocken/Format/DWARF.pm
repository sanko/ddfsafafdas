package Brocken::Format::DWARF {
    use v5.40;
    use utf8;
    use feature 'class';
    no warnings 'experimental::class';

    class Brocken::Format::DWARF {
        field $source_locs    : param : reader;
        field $text_base      : param : reader;
        field $source_file    : param : reader = 'source.brocken';
        field $func_ranges    : param : reader =[];
        field $context_size   : param : reader = 64;
        field $class_info     : param : reader = {};
        field $debug          : param : reader = 0;
        field $eh_frame_base  : param : reader = 0;
        field $arch           : param : reader = 'x64';
        field $preserved_regs : param : reader =[];
        field @pubnames;
        
        our %DWARF_REG = (
            rax => 0, rdx => 1, rcx => 2, rbx => 3, rsi => 4, rdi => 5, rbp => 6, rsp => 7,
            r8  => 8, r9  => 9, r10 => 10, r11 => 11, r12 => 12, r13 => 13, r14 => 14, r15 => 15,
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
            for my $e (@entries) {
                my $addr = $text_base + $e->{offset};
                my $line = $e->{line};
                $program .= "\x00" . $self->_uleb( 1 + 8 ) . "\x02" . pack( 'Q<', $addr );
                $program .= "\x03" . $self->_sleb( $line - $prev_line );
                $program .= "\x01";
                $prev_line = $line;
            }
            $program .= "\x00" . $self->_uleb(1) . "\x01";
            my $prologue = pack( 'C', 1 ) . pack( 'C', 1 ) . pack( 'c', -5 ) . pack( 'C', 14 ) . pack( 'C', 13 );
            $prologue .= pack( 'C*', 0, 1, 1, 1, 1, 0, 0, 0, 1, 0, 0, 1 );
            $prologue .= "\x00";
            $prologue .= "$source_file\x00" . $self->_uleb(0) . $self->_uleb(0) . $self->_uleb(0);
            $prologue .= "\x00";
            my $header = pack( 'L<', length($prologue) + length($program) + 6 );
            $header .= pack( 'S<', 2 );
            $header .= pack( 'L<', length($prologue) );
            $header .= $prologue;
            return $header . $program;
        }

        method build_debug_abbrev () {
            my $abbrev = '';

            # Abbrev 1: DW_TAG_compile_unit, DW_CHILDREN_yes
            $abbrev .= $self->_uleb(1);
            $abbrev .= $self->_uleb(0x11);                         # DW_TAG_compile_unit
            $abbrev .= $self->_uleb(1);                            # DW_CHILDREN_yes
            $abbrev .= $self->_uleb(0x10) . $self->_uleb(0x06);    # DW_AT_stmt_list -> DW_FORM_data4
            $abbrev .= $self->_uleb(0x03) . $self->_uleb(0x08);    # DW_AT_name -> DW_FORM_string
            $abbrev .= $self->_uleb(0x13) . $self->_uleb(0x0B);    # DW_AT_language -> DW_FORM_data1
            $abbrev .= pack( 'CC', 0, 0 );

            # Abbrev 2: DW_TAG_base_type, DW_CHILDREN_no
            $abbrev .= $self->_uleb(2);
            $abbrev .= $self->_uleb(0x24);                         # DW_TAG_base_type
            $abbrev .= $self->_uleb(0);                            # DW_CHILDREN_no
            $abbrev .= $self->_uleb(0x03) . $self->_uleb(0x08);    # DW_AT_name -> DW_FORM_string
            $abbrev .= $self->_uleb(0x0B) . $self->_uleb(0x0B);    # DW_AT_byte_size -> DW_FORM_data1
            $abbrev .= $self->_uleb(0x3E) . $self->_uleb(0x0B);    # DW_AT_encoding -> DW_FORM_data1
            $abbrev .= pack( 'CC', 0, 0 );

            # Abbrev 3: DW_TAG_subprogram, DW_CHILDREN_yes
            $abbrev .= $self->_uleb(3);
            $abbrev .= $self->_uleb(0x2E);                         # DW_TAG_subprogram
            $abbrev .= $self->_uleb(1);                            # DW_CHILDREN_yes
            $abbrev .= $self->_uleb(0x03) . $self->_uleb(0x08);    # DW_AT_name -> DW_FORM_string
            $abbrev .= $self->_uleb(0x11) . $self->_uleb(0x01);    # DW_AT_low_pc -> DW_FORM_addr
            $abbrev .= $self->_uleb(0x12) . $self->_uleb(0x01);    # DW_AT_high_pc -> DW_FORM_addr
            $abbrev .= $self->_uleb(0x40) . $self->_uleb(0x18);    # DW_AT_frame_base -> DW_FORM_exprloc
            $abbrev .= pack( 'CC', 0, 0 );

            # Abbrev 4: DW_TAG_formal_parameter, DW_CHILDREN_no
            $abbrev .= $self->_uleb(4);
            $abbrev .= $self->_uleb(0x05);                         # DW_TAG_formal_parameter
            $abbrev .= $self->_uleb(0);                            # DW_CHILDREN_no
            $abbrev .= $self->_uleb(0x03) . $self->_uleb(0x08);    # DW_AT_name -> DW_FORM_string
            $abbrev .= $self->_uleb(0x02) . $self->_uleb(0x18);    # DW_AT_location -> DW_FORM_exprloc
            $abbrev .= $self->_uleb(0x49) . $self->_uleb(0x13);    # DW_AT_type -> DW_FORM_ref4
            $abbrev .= pack( 'CC', 0, 0 );

            # Abbrev 5: DW_TAG_variable, DW_CHILDREN_no
            $abbrev .= $self->_uleb(5);
            $abbrev .= $self->_uleb(0x34);                         # DW_TAG_variable
            $abbrev .= $self->_uleb(0);                            # DW_CHILDREN_no
            $abbrev .= $self->_uleb(0x03) . $self->_uleb(0x08);    # DW_AT_name -> DW_FORM_string
            $abbrev .= $self->_uleb(0x02) . $self->_uleb(0x18);    # DW_AT_location -> DW_FORM_exprloc
            $abbrev .= $self->_uleb(0x49) . $self->_uleb(0x13);    # DW_AT_type -> DW_FORM_ref4
            $abbrev .= pack( 'CC', 0, 0 );

            # Abbrev 6: DW_TAG_structure_type, DW_CHILDREN_yes
            $abbrev .= $self->_uleb(6);
            $abbrev .= $self->_uleb(0x13);                         # DW_TAG_structure_type
            $abbrev .= $self->_uleb(1);                            # DW_CHILDREN_yes
            $abbrev .= $self->_uleb(0x03) . $self->_uleb(0x08);    # DW_AT_name -> DW_FORM_string
            $abbrev .= $self->_uleb(0x0B) . $self->_uleb(0x0B);    # DW_AT_byte_size -> DW_FORM_data1
            $abbrev .= pack( 'CC', 0, 0 );

            # Abbrev 7: DW_TAG_member, DW_CHILDREN_no
            $abbrev .= $self->_uleb(7);
            $abbrev .= $self->_uleb(0x0D);                         # DW_TAG_member
            $abbrev .= $self->_uleb(0);                            # DW_CHILDREN_no
            $abbrev .= $self->_uleb(0x03) . $self->_uleb(0x08);    # DW_AT_name -> DW_FORM_string
            $abbrev .= $self->_uleb(0x38) . $self->_uleb(0x0B);    # DW_AT_data_member_location -> DW_FORM_data1
            $abbrev .= $self->_uleb(0x49) . $self->_uleb(0x13);    # DW_AT_type -> DW_FORM_ref4
            $abbrev .= pack( 'CC', 0, 0 );

            # Abbrev 8: DW_TAG_array_type, DW_CHILDREN_yes
            $abbrev .= $self->_uleb(8);
            $abbrev .= $self->_uleb(0x01);                         # DW_TAG_array_type
            $abbrev .= $self->_uleb(1);                            # DW_CHILDREN_yes
            $abbrev .= $self->_uleb(0x49) . $self->_uleb(0x13);    # DW_AT_type -> DW_FORM_ref4
            $abbrev .= pack( 'CC', 0, 0 );

            # Abbrev 9: DW_TAG_subrange_type, DW_CHILDREN_no
            $abbrev .= $self->_uleb(9);
            $abbrev .= $self->_uleb(0x21);                         # DW_TAG_subrange_type
            $abbrev .= $self->_uleb(0);                            # DW_CHILDREN_no
            $abbrev .= $self->_uleb(0x3F) . $self->_uleb(0x0B);    # DW_AT_count -> DW_FORM_data1
            $abbrev .= pack( 'CC', 0, 0 );
            $abbrev .= "\x00";                                     # end of abbreviations table
            return $abbrev;
        }

        method build_debug_info () {
            my $cu_body = '';
            $cu_body .= $self->_uleb(1);                           # abbrev code 1 (DW_TAG_compile_unit)
            $cu_body .= pack( 'L<', 0 );                           # DW_AT_stmt_list -> offset 0 into .debug_line
            $cu_body .= "$source_file\0";                          # DW_AT_name
            $cu_body .= pack( 'C', 12 );                           # DW_AT_language -> DW_LANG_C99 (12)

            # Children: base types
            my $CU_HEADER_SIZE = 11;                               # unit_length(4) + version(2) + abbrev_off(4) + addr_size(1)
            my $type_off       = {};
            for my $t ([ 'Int', 5 ], [ 'Bool', 2 ], [ 'String', 1 ],[ 'Any', 1 ], [ 'ptr', 1 ], [ 'Array', 1 ] ) {
                my ( $name, $enc ) = @$t;
                $type_off->{$name} = $CU_HEADER_SIZE + length($cu_body);
                $cu_body .= $self->_uleb(2);      # abbrev code 2 (DW_TAG_base_type)
                $cu_body .= "$name\0";            # DW_AT_name
                $cu_body .= pack( 'C', 8 );       # DW_AT_byte_size
                $cu_body .= pack( 'C', $enc );    # DW_AT_encoding
            }

            # Children: structure types (class definitions) - Level 4
            if ( $self->debug >= 4 ) {
                for my $cn ( sort keys %$class_info ) {
                    my $ci     = $class_info->{$cn};
                    my @fields = @{ $ci->{fields} };
                    $type_off->{$cn} = $CU_HEADER_SIZE + length($cu_body);
                    $cu_body .= $self->_uleb(6);                          # abbrev 6 (DW_TAG_structure_type)
                    $cu_body .= "$cn\0";                                  # DW_AT_name
                    $cu_body .= pack( 'C', 16 + scalar(@fields) * 8 );    # DW_AT_byte_size
                    for my $i ( 0 .. $#fields ) {
                        my $f = $fields[$i];
                        $cu_body .= $self->_uleb(7);             # abbrev 7 (DW_TAG_member)
                        $cu_body .= $f->name . "\0";             # DW_AT_name
                        $cu_body .= pack( 'C', 16 + $i * 8 );    # DW_AT_data_member_location
                        my $ft = $type_off->{ $f->type } // $type_off->{Any};
                        $cu_body .= pack( 'L<', $ft );           # DW_AT_type -> ref4
                    }
                    $cu_body .= "\0";                            # end of structure_type children
                }
            }

            # Children: subprograms with parameters or locals
            my @fns = sort { $a->{start} <=> $b->{start} } @$func_ranges;
            for my $fn (@fns) {
                next unless ( $fn->{params} && @{ $fn->{params} } ) || ( $fn->{locals} && @{ $fn->{locals} } );
                my $die_off = $CU_HEADER_SIZE + length($cu_body);
                $cu_body .= $self->_uleb(3);                                              # abbrev code 3 (DW_TAG_subprogram)
                my $pn = $fn->{name};
                $pn =~ s/^M_//;
                $pn = 'main'                                        if $pn eq 'L_MAIN_START';
                push @pubnames, { offset => $die_off, name => $pn } if $pn;
                $cu_body .= "$fn->{name}\0";                                              # DW_AT_name
                $cu_body .= pack( 'Q<', $text_base + $fn->{start} );                      # DW_AT_low_pc
                $cu_body .= pack( 'Q<', $text_base + ( $fn->{end} // $fn->{start} ) );    # DW_AT_high_pc
                
                # DW_AT_frame_base: exprloc(len=2, DW_OP_bregX(0))
                my $fp_op = 0x70 + ($arch eq 'arm64' ? 29 : 6);
                $cu_body .= "\x02" . pack('C', $fp_op) . "\x00";

                for my $p ( @{ $fn->{params} //[] } ) {
                    $cu_body .= $self->_uleb(4);                                          # abbrev code 4 (DW_TAG_formal_parameter)
                    ( my $dw_name = $p->{name} ) =~ s/^\$//;
                    $cu_body .= "$dw_name\0";                                             # DW_AT_name (strip $prefix for GDB)
                    my $loc = "\x91" . $self->_sleb( -$p->{slot} );                       # DW_OP_fbreg (frame_base = RBP/X29)
                    $cu_body .= $self->_uleb( length($loc) ) . $loc;
                    my $to = $type_off->{ $p->{type} } // $type_off->{Any};
                    $cu_body .= pack( 'L<', $to );                                        # DW_AT_type -> ref4
                }
                for my $v ( @{ $fn->{locals} //[] } ) {
                    $cu_body .= $self->_uleb(5);                                          # abbrev code 5 (DW_TAG_variable)
                    ( my $dw_name = $v->{name} ) =~ s/^\$//;
                    $cu_body .= "$dw_name\0";                                             # DW_AT_name (strip $prefix)
                    my $loc = "\x91" . $self->_sleb( -$v->{slot} );                       # DW_OP_fbreg (frame_base = RBP/X29)
                    $cu_body .= $self->_uleb( length($loc) ) . $loc;
                    my $to = $type_off->{ $v->{type} } // $type_off->{Any};
                    $cu_body .= pack( 'L<', $to );                                        # DW_AT_type -> ref4
                }
                $cu_body .= "\0";                                                         # end of subprogram children
            }
            $cu_body .= "\0";                                                             # end of CU children
            my $cu_len = 2 + 4 + 1 + length($cu_body);                                    # version(2) + abbrev_off(4) + addr_size(1) + body
            my $hdr    = pack( 'L< S< L< C', $cu_len, 2, 0, 8 );
            return $hdr . $cu_body;
        }

        method _dwarf_reg ($name) {
            if ($arch eq 'arm64') {
                return $1 if $name =~ /^x(\d+)$/;
                return 31 if $name eq 'sp';
            } else {
                return $DWARF_REG{$name} if exists $DWARF_REG{$name};
            }
            die "Unknown DWARF register: $name";
        }

        method build_debug_frame () {
            my $data   = '';
            my $offset = 0;

            # --- CIE ---
            my $cie_body = '';
            $cie_body .= pack( 'C', 3 );      # version = 3 (DWARF3)
            $cie_body .= "\x00";              # augmentation = ""
            $cie_body .= $self->_uleb( 1);    # code_alignment_factor = 1
            $cie_body .= $self->_sleb(-8);    # data_alignment_factor = -8
            
            if ($arch eq 'arm64') {
                $cie_body .= $self->_uleb(30); # return_address_register = x30
                $cie_body .= "\x0C" . $self->_uleb(31) . $self->_uleb(0); # DW_CFA_def_cfa: sp, 0
            } else {
                $cie_body .= $self->_uleb(16); # return_address_register = 16
                $cie_body .= "\x0C" . $self->_uleb(7) . $self->_uleb(8);     # DW_CFA_def_cfa: rsp(7), +8
                $cie_body .= "\x02" . $self->_uleb(16) . $self->_uleb(1);    # DW_CFA_offset: ra(16), +1
            }

            my $cie_len = 4 + length($cie_body);                         # includes CIE_id (4) + body
            $data .= pack( 'L<', $cie_len );                             # CIE length
            $data .= pack( 'L<', 0xFFFFFFFF );                           # CIE_id = -1 (DWARF3)
            $data .= $cie_body;
            $offset += 4 + $cie_len;                                     # cie_end = start of FDEs

            # --- FDEs ---
            my @fns = sort { $a->{start} <=> $b->{start} } @$func_ranges;
            for my $fn (@fns) {
                my $start_addr = $text_base + $fn->{start};
                my $range      = $fn->{end} ? ( $text_base + $fn->{end} - $start_addr ) : 1;

                my $cfa_off  = $arch eq 'arm64' ? $context_size : $context_size + 8;
                my $fp_dwarf = $arch eq 'arm64' ? 29 : 6;
                my $instr    = "\x0C" . $self->_uleb($fp_dwarf) . $self->_uleb($cfa_off);    # DW_CFA_def_cfa: FP, cfa_off

                my $regs = $preserved_regs;
                for my $i ( 0 .. $#$regs ) {
                    my $dwarf    = $self->_dwarf_reg( $regs->[$i] );
                    my $save_off = $arch eq 'arm64' ? ($i + 1) * 2 : ($i + 2);
                    $instr .= "\x02" . $self->_uleb($dwarf) . $self->_uleb($save_off);
                }
                
                my $fde_body = pack( 'Q<', $start_addr ) . pack( 'Q<', $range ) . $instr;
                my $fde_len  = 4 + length($fde_body);                                       # CIE_ptr + body
                $data .= pack( 'L<', $fde_len );                                            # FDE length
                my $cie_ptr = 0 - ( $offset + 4 );
                $data .= pack( 'L<', $cie_ptr & 0xFFFFFFFF );                               # CIE_pointer (unsigned)
                $data .= $fde_body;
                $offset += 4 + $fde_len;
            }
            return $data;
        }

        method build_eh_frame () {
            my $data   = '';
            my $offset = 0;

            # --- CIE ---
            my $cie_body = '';
            $cie_body .= pack( 'C', 1 );       # version = 1 (eh_frame)
            $cie_body .= "zR\0";               # augmentation = "zR"
            $cie_body .= $self->_uleb(1);      # code_alignment_factor = 1
            $cie_body .= $self->_sleb(-8);     # data_alignment_factor = -8
            
            if ($arch eq 'arm64') {
                $cie_body .= $self->_uleb(30);     # return_address_register = 30
                $cie_body .= $self->_uleb(1);      # augmentation data length
                $cie_body .= pack( 'C', 0x1B );    # FDE encoding: DW_EH_PE_pcrel | DW_EH_PE_sdata4
                $cie_body .= "\x0C" . $self->_uleb(31) . $self->_uleb(0);
            } else {
                $cie_body .= $self->_uleb(16);     # return_address_register = 16
                $cie_body .= $self->_uleb(1);      # augmentation data length
                $cie_body .= pack( 'C', 0x1B );    # FDE encoding: DW_EH_PE_pcrel | DW_EH_PE_sdata4
                $cie_body .= "\x0C" . $self->_uleb(7) . $self->_uleb(8);
                $cie_body .= "\x02" . $self->_uleb(16) . $self->_uleb(1);
            }
            
            my $cie_len = 4 + length($cie_body);
            $data .= pack( 'L<', $cie_len );
            $data .= pack( 'L<', 0 );          # CIE_id = 0 (eh_frame)
            $data .= $cie_body;
            $offset += 4 + $cie_len;

            # --- FDEs ---
            my $text_base = $self->text_base;
            my $eh_base   = $self->eh_frame_base;
            my @fns       = sort { $a->{start} <=> $b->{start} } @$func_ranges;
            for my $fn (@fns) {
                my $range    = $fn->{end} ? ( $fn->{end} - $fn->{start} ) : 1;
                my $cfa_off  = $arch eq 'arm64' ? $context_size : $context_size + 8;
                my $fp_dwarf = $arch eq 'arm64' ? 29 : 6;
                my $instr    = "\x0C" . $self->_uleb($fp_dwarf) . $self->_uleb($cfa_off);
                
                my $regs    = $preserved_regs;
                for my $i ( 0 .. $#$regs ) {
                    my $dwarf    = $self->_dwarf_reg( $regs->[$i] );
                    my $save_off = $arch eq 'arm64' ? ($i + 1) * 2 : ($i + 2);
                    $instr .= "\x02" . $self->_uleb($dwarf) . $self->_uleb($save_off);
                }
                
                my $fde_body = '';
                $fde_body .= pack( 'l<', ( $text_base + $fn->{start} ) - ( $eh_base + $offset + 8 ) );
                $fde_body .= pack( 'L<', $range );
                $fde_body .= $self->_uleb(0);
                $fde_body .= $instr;
                my $fde_len = 4 + length($fde_body);
                $data .= pack( 'L<', $fde_len );
                $data .= pack( 'L<', ( 0 - ( $offset + 4 ) ) & 0xFFFFFFFF );
                $data .= $fde_body;
                $offset += 4 + $fde_len;
            }
            return $data;
        }

        method build_debug_aranges () {
            my $data        = '';
            my @fns         = sort { $a->{start} <=> $b->{start} } @$func_ranges;
            my $header_size = 4 + 2 + 4 + 1 + 1;                                    # unit_length + version + debug_info_offset + addr_size + seg_size
            my $pad         = ( 2 * 8 - ( $header_size % ( 2 * 8 ) ) ) % ( 2 * 8 );
            my $body        = '';
            for my $fn (@fns) {
                my $start = $text_base + $fn->{start};
                my $len   = $fn->{end} ? ( $text_base + $fn->{end} - $start ) : 1;
                $body .= pack( 'Q<', $start ) . pack( 'Q<', $len );
            }
            $body .= pack( 'Q<', 0 ) . pack( 'Q<', 0 );                             # terminator
            my $unit_len = 2 + 4 + 1 + 1 + $pad + length($body);
            $data .= pack( 'L<', $unit_len );
            $data .= pack( 'S<', 2 );                                               # version
            $data .= pack( 'L<', 0 );                                               # debug_info_offset (our CU is first)
            $data .= pack( 'C',  8 );                                               # address_size
            $data .= pack( 'C',  0 );                                               # segment_size
            $data .= "\x00" x $pad;                                                 # padding
            $data .= $body;
            return $data;
        }

        method build_debug_pubnames ( $info_len = 0 ) {
            my $data = '';
            my $body = '';
            for my $pn (@pubnames) {
                $body .= pack( 'L<', $pn->{offset} ) . "$pn->{name}\0";
            }
            $body .= pack( 'L<', 0 );                                               # terminator
            my $unit_len = 2 + 4 + 4 + length($body);
            $data .= pack( 'L<', $unit_len );
            $data .= pack( 'S<', 2 );                                               # version
            $data .= pack( 'L<', 0 );                                               # debug_info_offset
            $data .= pack( 'L<', $info_len );                                       # debug_info_length
            $data .= $body;
            return $data;
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
            my $out  = '';
            my $more = 1;
            while ($more) {
                my $byte = $v & 0x7F;
                { use integer; $v >>= 7; }
                if ( ( $v == 0 && !( $byte & 0x40 ) ) || ( $v == -1 && ( $byte & 0x40 ) ) ) { $more = 0; }
                else                                                                        { $byte |= 0x80; }
                $out .= pack( 'C', $byte );
            }
            return $out;
        }
    }
}
1;