use v5.40;
use feature 'class';
class Brocken::Target::X64 : isa(Brocken::Target) {
    use v5.40;
    use feature 'class';

    method registers() {
        # Reserved: rax (returns), r10/r11 (scratch), r14 (Isolate), rbp/rsp (stack)
        return $self->os eq 'win64'
            ? [qw(rbx rsi rdi r12 r13 r15)]
            : [qw(rbx r12 r13 r15)];
    }

    method _abi_arg_reg($idx) {
        if ($self->os eq 'win64') { return (qw[rcx rdx r8 r9])[$idx] // 'stack'; }
        else                { return (qw[rdi rsi rdx rcx r8 r9])[$idx] // 'stack'; }
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
            if ($inst->{args}[0] =~ /^%/ || $inst->{args}[0] =~ /^[a-z]/i) { $as->mov_reg($d_reg, $s) if $d_reg ne $s; }
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
            $as->append_code(pack('CC', 0x48, 0x99)); # cqto
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
            my $regs = $driver->preserved_regs();
            for my $r (@$regs) { $as->push_reg($r); }
            $as->mov_reg('rbp', 'rsp');
            $as->sub_imm('rsp', $driver->frame_local_size);
        }
        elsif ($op eq 'leave_func') {
            my $rv = $v->($inst->{args}[0]);
            if (defined $rv) { $inst->{args}[0] =~ /^%/ ? $as->mov_reg('rax', $reg_map->{$inst->{args}[0]}) : $as->mov_imm('rax', $rv); }
            $as->add_imm('rsp', $driver->frame_local_size);
            my $regs = $driver->preserved_regs();
            for my $r (reverse @$regs) { $as->pop_reg($r); }
            $as->append_code(pack('C', 0xC3));
        }
        elsif ($op =~ /^call_(func|reg)$/) {
            my @args = @{$inst->{args}};
            my $target = ($op eq 'call_func') ? shift @args : $reg_map->{shift @args};
            for my $i (0 .. $#args) {
                my $arg = $args[$i]; my $dst = $self->_abi_arg_reg($i);
                if    ($arg =~ /^%/)      { $as->mov_reg($dst, $reg_map->{$arg}); }
                elsif ($arg =~ /^[A-Z_]/i) { $as->lea_rva($dst, $arg, $driver->text_rva); }
                else                       { $as->mov_imm($dst, $arg); }
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
    }

    method compile_intrinsic($as, $inst, $reg_map, $driver) {
        my $op = $inst->{op};
        my $v  = sub { $self->val($reg_map, shift) };

        if ($op eq 'intrinsic_alloc') {
            my $d = $reg_map->{$inst->{dest}}; my $sz = $v->($inst->{args}[0]);
            if ($self->os eq 'win64') {
                $as->mov_imm('rcx', 0);
                $inst->{args}[0] =~ /^%/ ? $as->mov_reg('rdx', $reg_map->{$inst->{args}[0]}) : $as->mov_imm('rdx', $sz);
                $as->mov_imm('r8', 0x3000); $as->mov_imm('r9', 0x04);
                $as->call_rva($driver->import_rva('VirtualAlloc'), $driver->text_rva);
                $as->mov_reg($d, 'rax');
            } else {
                $as->mov_imm('rax', 9); $as->mov_imm('rdi', 0);
                $inst->{args}[0] =~ /^%/ ? $as->mov_reg('rsi', $reg_map->{$inst->{args}[0]}) : $as->mov_imm('rsi', $sz);
                $as->mov_imm('rdx', 3); $as->mov_imm('r10', 0x22); $as->mov_imm('r8', -1); $as->mov_imm('r9', 0);
                $as->syscall(); $as->mov_reg($d, 'rax');
            }
        }
        elsif ($op eq 'intrinsic_print') {
            my $p = $reg_map->{$inst->{args}[0]};
            if ($self->os eq 'win64') {
                $as->mov_imm('rcx', -11); $as->call_rva($driver->import_rva('GetStdHandle'), $driver->text_rva);
                $as->mov_reg('rcx', 'rax'); $as->mov_reg('rdx', $p); $as->add_imm('rdx', 24);
                $as->load_reg_mem('r8', $p, 0); $as->lea_reg_disp('r9', 'rsp', 40);
                $as->mov_imm('rax', 0); $as->store_mem_disp_reg('rsp', 32, 'rax');
                $as->call_rva($driver->import_rva('WriteFile'), $driver->text_rva);
            } else {
                $as->mov_reg('rsi', $p); $as->load_reg_mem('rdx', 'rsi', 0); $as->add_imm('rsi', 24);
                $as->mov_imm('rdi', 1); $as->mov_imm('rax', 1); $as->syscall();
            }
        }
        elsif ($op eq 'intrinsic_exit') {
            my $val = $v->($inst->{args}[0]);
            if ($self->os eq 'win64') { $as->mov_reg('rcx', $val); $as->call_rva($driver->import_rva('ExitProcess'), $driver->text_rva); }
            else { $as->mov_imm('rax', 60); $as->mov_reg('rdi', $val); $as->syscall(); }
        }
        elsif ($op eq 'intrinsic_emit_runtime') {
            if ($self->os eq 'win64') {
                $as->mark_label('M_veh_handler'); $as->load_reg_mem('rax', 'rcx', 0);
                $as->append_code(pack('CCC', 0x44, 0x8B, 0x18)); $as->cmp_reg_imm_32('r11', 0xC0000005);
                $as->jcc(5, 'veh_not_handled'); $as->load_reg_mem('r8', 'rax', 40); $as->mov_imm('r11', -4096);
                $as->append_code(pack('CCC', 0x4D, 0x21, 0xD8)); $as->sub_imm('rsp', 40); $as->mov_reg('rcx', 'r8');
                $as->mov_imm('rdx', 4096); $as->mov_imm('r8', 0x1000); $as->mov_imm('r9', 4);
                $as->call_rva($driver->import_rva('VirtualAlloc'), $driver->text_rva); $as->add_imm('rsp', 40);
                $as->cmp_reg_imm('rax', 0); $as->jcc(4, 'veh_not_handled'); $as->mov_imm('rax', -1); $as->append_code(pack('C', 0xC3));
                $as->mark_label('veh_not_handled'); $as->mov_imm('rax', 0); $as->append_code(pack('C', 0xC3));
            }
            $as->mark_label('M_fiber_switch');
            my $regs = $driver->preserved_regs();
            for my $r (@$regs) { $as->push_reg($r); }
            if ($self->os eq 'win64') { $as->mov_reg('rax', 'rdx'); $as->mov_reg('r10', 'rcx'); }
            else                { $as->mov_reg('rax', 'rsi'); $as->mov_reg('r10', 'rdi'); }
            $as->load_reg_mem('r11', 'r14', $driver->iso_offset('current_fcb'));
            $as->store_mem_disp_reg('r11', $driver->fcb_offset('sp'), 'rsp');
            $as->store_mem_disp_reg('r10', $driver->fcb_offset('caller'), 'r11');
            $as->store_mem_disp_reg('r14', $driver->iso_offset('current_fcb'), 'r10');
            $as->load_reg_mem('rsp', 'r10', $driver->fcb_offset('sp'));
            for my $r (reverse @$regs) { $as->pop_reg($r); }
            $as->append_code(pack('C', 0xC3));
        }
        elsif ($op eq 'intrinsic_setup_env') {
            if ($self->os eq 'win64') { $as->mov_imm('rcx', 65001); $as->call_rva($driver->import_rva('SetConsoleOutputCP'), $driver->text_rva); }
        }
        elsif ($op eq 'intrinsic_setup_fault_handler') {
            if ($self->os eq 'win64') { $as->mov_imm('rcx', 1); $as->lea_rva('rdx', 'M_veh_handler', $driver->text_rva); $as->call_rva($driver->import_rva('AddVectoredExceptionHandler'), $driver->text_rva); }
        }
    }
}
1;
