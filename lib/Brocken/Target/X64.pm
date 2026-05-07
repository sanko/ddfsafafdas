package Brocken::Target::X64 {
    use v5.40;
    use feature 'class';

    no warnings 'experimental::class';
    class Brocken::Target::X64 : isa(Brocken::Target) {

        method registers() {
            # Use $self->os instead of $os
            return $self->os eq 'win64'
                ? [qw(rbx rsi rdi r12 r13 r15)]
                : [qw(rbx r12 r13 r15)];
        }

        method _abi_arg_reg($idx) {
            if ($self->os eq 'win64') { return (qw[rcx rdx r8 r9])[$idx] // 'stack'; }
            else                      { return (qw[rdi rsi rdx rcx r8 r9])[$idx] // 'stack'; }
        }

        method emit_op($as, $inst, $reg_map, $driver) {
            my $op = $inst->{op};
            my $v  = sub { $self->val($reg_map, shift) };
            my $d_reg = $reg_map->{$inst->{dest}} if $inst->{dest};

            if    ($op eq 'jmp')   { $as->jmp($inst->{target}); }
            elsif ($op eq 'cond_br') {
                my $reg = $v->($inst->{reg});
                $as->test_reg_reg($reg, $reg);
                $as->jcc($driver->cc('nz'), $inst->{true_l});
                $as->jmp($inst->{false_l});
            }
            elsif ($op eq 'constant') { $as->mov_imm($d_reg, $inst->{args}[0]); }
            elsif ($op eq 'mov') {
                my $s = $v->($inst->{args}[0]);
                if ($inst->{args}[0] =~ /^%/ || $inst->{args}[0] =~ /^[a-z]/i) { $as->mov_reg($d_reg, $s) if ($d_reg // '') ne ($s // ''); }
                else { $as->mov_imm($d_reg, $s); }
            }
            elsif ($op =~ /^(add|sub|mul)$/) {
                my $lv = $v->($inst->{args}[0]); my $rv = $v->($inst->{args}[1]);
                $as->mov_reg($d_reg, $lv) if $d_reg ne $lv;
                if ($inst->{args}[1] =~ /^%/) {
                    my $rs = $reg_map->{$inst->{args}[1]};
                    if    ($op eq 'add') { $as->add_reg($d_reg, $rs); }
                    elsif ($op eq 'sub') { $as->sub_reg($d_reg, $rs); }
                    else                 { $as->mul_reg($d_reg, $rs); }
                } else {
                    if    ($op eq 'add') { $as->add_imm($d_reg, $rv); }
                    elsif ($op eq 'sub') { $as->sub_imm($d_reg, $rv); }
                    else                 { $as->mov_imm('r11', $rv); $as->mul_reg($d_reg, 'r11'); }
                }
            }
            elsif ($op =~ /^(div|mod)$/) {
                $as->mov_reg('rax', $v->($inst->{args}[0]));
                $as->append_code(pack('CC', 0x48, 0x99));
                if ($inst->{args}[1] =~ /^%/) { $as->idiv_reg($reg_map->{$inst->{args}[1]}); }
                else { $as->mov_imm('r11', $inst->{args}[1]); $as->idiv_reg('r11'); }
                $as->mov_reg($d_reg, $op eq 'div' ? 'rax' : 'rdx');
            }
            elsif ($op =~ /^cmp_(eq|ne|lt|gt|le|ge)$/) {
                my $type = $1; my $lv = $v->($inst->{args}[0]); my $rv = $v->($inst->{args}[1]);
                $inst->{args}[1] =~ /^%/ ? $as->cmp_reg_reg($lv, $reg_map->{$inst->{args}[1]}) : $as->cmp_reg_imm($lv, $rv);
                $as->mov_imm($d_reg, 0);
                my $cc_map = { eq => 0x94, ne => 0x95, lt => 0x9C, ge => 0x9D, le => 0x9E, gt => 0x9F };
                $as->setcc($cc_map->{$type}, $d_reg);
            }
            # Inside Brocken::Target::X64 -> emit_op
            elsif ($op =~ /^(add|sub|mul|and|or|xor)$/) {
                my $lv = $v->($inst->{args}[0]); my $rv = $v->($inst->{args}[1]);
                $as->mov_reg($d_reg, $lv) if $d_reg ne $lv;
                if ($inst->{args}[1] =~ /^%/) {
                    my $rs = $reg_map->{$inst->{args}[1]};
                    if    ($op eq 'add') { $as->add_reg($d_reg, $rs); }
                    elsif ($op eq 'sub') { $as->sub_reg($d_reg, $rs); }
                    elsif ($op eq 'and') { $as->and_reg($d_reg, $rs); }
                    elsif ($op eq 'or')  { $as->or_reg($d_reg, $rs); }
                    elsif ($op eq 'xor') { $as->xor_reg($d_reg, $rs); }
                    else                 { $as->mul_reg($d_reg, $rs); }
                } else {
                    if    ($op eq 'add') { $as->add_imm($d_reg, $rv); }
                    elsif ($op eq 'sub') { $as->sub_imm($d_reg, $rv); }
                    elsif ($op eq 'and') { $as->and_imm($d_reg, $rv); }
                    elsif ($op eq 'or')  { $as->or_imm($d_reg, $rv); }
                    elsif ($op eq 'xor') { $as->xor_imm($d_reg, $rv); }
                    else                 { $as->mov_imm('r11', $rv); $as->mul_reg($d_reg, 'r11'); }
                }
            }elsif ($op =~ /^(shl|shr)$/) {
                my $val = $v->($inst->{args}[0]);
                my $amt = $inst->{args}[1];

                if ($amt !~ /^%/) {
                    # Constant shift (already implemented)
                    if ($inst->{args}[0] =~ /^%/) { $as->mov_reg($d_reg, $val) if $d_reg ne $val; }
                    else                          { $as->mov_imm($d_reg, $val); }

                    if ($op eq 'shl') { $as->shl_imm($d_reg, $v->($amt)); }
                    else              { $as->shr_imm($d_reg, $v->($amt)); }
                } else {
                    # Variable shift: Amount must be in RCX
                    my $amt_reg = $reg_map->{$amt};
                    $as->mov_reg('rcx', $amt_reg) if $amt_reg ne 'rcx';

                    # Load the value to be shifted into the destination
                    if ($inst->{args}[0] =~ /^%/) { $as->mov_reg($d_reg, $val) if $d_reg ne $val; }
                    else                          { $as->mov_imm($d_reg, $val); }

                    # Perform the shift using CL
                    if ($op eq 'shl') { $as->shl_cl($d_reg); }
                    else              { $as->shr_cl($d_reg); }
                }
            }
            elsif ($op eq 'local_store') {
                my $val = $v->($inst->{args}[1]);
                if ($inst->{args}[1] !~ /^%/) { $as->mov_imm('r11', $val); $as->store_mem_disp_reg('rbp', -$inst->{args}[0], 'r11'); }
                else { $as->store_mem_disp_reg('rbp', -$inst->{args}[0], $val); }
            }
            elsif ($op eq 'local_load') {
                $as->load_reg_mem($d_reg, 'rbp', -$inst->{args}[0]);
            }
            elsif ($op eq 'load_mem_disp') { $as->load_reg_mem($d_reg, $reg_map->{$inst->{args}[0]}, $inst->{args}[1]); }
            elsif ($op eq 'store_mem_disp') { $as->store_mem_disp_reg($reg_map->{$inst->{args}[0]}, $inst->{args}[1], $v->($inst->{args}[2])); }
            elsif ($op eq 'load_mem_byte') {
                my $base = $reg_map->{$inst->{args}[0]}; my $idx = $inst->{args}[1];
                if ($idx =~ /^%/) { $as->mov_reg('r11', $base); $as->add_reg('r11', $reg_map->{$idx}); $as->load_reg_mem_byte($d_reg, 'r11', 0); }
                else { $as->load_reg_mem_byte($d_reg, $base, $idx); }
            }
            elsif ($op eq 'store_mem_byte') {
                my $base = $reg_map->{$inst->{args}[0]}; my $idx = $inst->{args}[1]; my $src = ($inst->{args}[2] =~ /^%/) ? $reg_map->{$inst->{args}[2]} : 'r11';
                $as->mov_imm('r11', $v->($inst->{args}[2])) if $inst->{args}[2] !~ /^%/;
                if ($idx =~ /^%/) { $as->push_reg('rax'); $as->mov_reg('rax', $base); $as->add_reg('rax', $reg_map->{$idx}); $as->store_mem_disp_byte('rax', 0, $src); $as->pop_reg('rax'); }
                else { $as->store_mem_disp_byte($base, $idx, $src); }
            }
            elsif ($op eq 'load_iso_disp') { $as->load_reg_mem($d_reg, 'r14', $inst->{args}[0]); }
            elsif ($op eq 'store_iso_disp') { $as->store_mem_disp_reg('r14', $inst->{args}[0], $v->($inst->{args}[1])); }
            elsif ($op eq 'load_func_addr' || $op eq 'load_data_addr') {
                my $target = $inst->{args}[0];
                if ($target =~ /^\d+$/) { my $base = ($op eq 'load_data_addr') ? $driver->data_rva : 0; $as->lea_rva($d_reg, $base + $target, $driver->text_rva); }
                else { $as->lea_rva($d_reg, $target, $driver->text_rva); }
            }
            elsif ($op eq 'get_arg') { $as->mov_reg($d_reg, $self->_abi_arg_reg($inst->{args}[0])); }
            elsif ($op eq 'set_isolate_ctx') { $as->mov_reg('r14', $reg_map->{$inst->{args}[0]}); }
            elsif ($op eq 'get_isolate_ctx') { $as->mov_reg($d_reg, 'r14'); }
            elsif ($op eq 'enter_func') {
                my $regs = $driver->preserved_regs(); for my $r (@$regs) { $as->push_reg($r); }
                $as->mov_reg('rbp', 'rsp'); $as->sub_imm('rsp', $driver->frame_local_size);
            }
            elsif ($op eq 'leave_func') {
                my $rv = $v->($inst->{args}[0]);
                if (defined $rv) { $inst->{args}[0] =~ /^%/ ? $as->mov_reg('rax', $reg_map->{$inst->{args}[0]}) : $as->mov_imm('rax', $rv); }
                $as->add_imm('rsp', $driver->frame_local_size);
                my $regs = $driver->preserved_regs(); for my $r (reverse @$regs) { $as->pop_reg($r); }
                $as->append_code(pack('C', 0xC3));
            }
            elsif ($op =~ /^call_(func|reg)$/) {
                my @args = @{$inst->{args}}; my $target = ($op eq 'call_func') ? shift @args : $reg_map->{shift @args};
                for my $i (0 .. $#args) {
                    my $arg = $args[$i]; my $dst = $self->_abi_arg_reg($i);
                    if ($arg =~ /^%/) { $as->mov_reg($dst, $reg_map->{$arg}); }
                    elsif ($arg =~ /^[A-Z_]/i) { $as->lea_rva($dst, $arg, $driver->text_rva); }
                    else { $as->mov_imm($dst, $arg); }
                }
                if ($op eq 'call_func') { $as->call_label($target); }
                else { $as->mov_reg('r11', $target); $as->append_code(pack('CCC', 0x41, 0xFF, 0xD3)); }
                $as->mov_reg($d_reg, 'rax') if defined $d_reg;
            }
             elsif ($op eq 'shadow_push') {
                my $val = $v->($inst->{args}[0]);
                $as->load_reg_mem('r11', 'r14', $driver->iso_offset('current_fcb'));
                $as->load_reg_mem('rax', 'r11', $driver->fcb_offset('shadow_ptr'));
                if ($inst->{args}[0] =~ /^%/) { $as->store_mem_disp_reg('rax', 0, $reg_map->{$inst->{args}[0]}); }
                else { $as->mov_imm('r11', $val); $as->store_mem_disp_reg('rax', 0, 'r11'); }
                $as->add_imm('rax', 8);
                $as->load_reg_mem('r11', 'r14', $driver->iso_offset('current_fcb'));
                $as->store_mem_disp_reg('r11', $driver->fcb_offset('shadow_ptr'), 'rax');
            }
            elsif ($op eq 'shadow_get') { # Get the current shadown stack height
                $as->load_reg_mem('r11', 'r14', $driver->iso_offset('current_fcb'));
                $as->load_reg_mem($d_reg, 'r11', $driver->fcb_offset('shadow_ptr'));
            }elsif ($op eq 'shadow_set') { # Restore shadow stack to previous height
                $as->load_reg_mem('r11', 'r14', $driver->iso_offset('current_fcb'));
                $as->store_mem_disp_reg('r11', $driver->fcb_offset('shadow_ptr'), $v->($inst->{args}[0]));
            }

            elsif ($op eq 'get_sp') { $as->mov_reg($d_reg, 'rsp'); }
            elsif ($op eq 'shadow_restore') {
                      $as->load_reg_mem('r11', 'r14', $driver->iso_offset('current_fcb'));
                $as->store_mem_disp_reg('r11', $driver->fcb_offset('shadow_ptr'), $v->($inst->{args}[0]));
            } elsif ($op eq 'map_op') {
                # Map loop fusion is pending. Return tagged 0 (1) to prevent GC crashes.
                $as->mov_imm($d_reg, 1) if defined $d_reg;
            }
            }

        method compile_intrinsic($as, $inst, $reg_map, $driver) {
            # Pure delegation to the platform
            return $driver->platform->emit_intrinsic($self, $as, $inst, $reg_map, $driver);
        }
    }
}
1;
