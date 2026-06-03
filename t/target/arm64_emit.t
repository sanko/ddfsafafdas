use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
require Brocken::Target::Architecture::ARM64;
subtest 'Register mapping' => sub {
    my $as = Brocken::Target::Architecture::ARM64::Emit->new;
    is $as->reg('x0'),  0,  'x0 = 0';
    is $as->reg('x19'), 19, 'x19 = 19';
    is $as->reg('x30'), 30, 'lr/x30 = 30';
    is $as->reg('sp'),  31, 'sp = 31';
    is $as->reg('xzr'), 31, 'xzr = 31';
    is $as->reg('d0'),  0,  'd0 = 0';
    is $as->reg('d15'), 15, 'd15 = 15';
    ok dies { $as->reg('foo') }, 'invalid register dies';
};
subtest 'Push and pop' => sub {
    my $as = Brocken::Target::Architecture::ARM64::Emit->new;
    $as->push_reg('x19');
    $as->pop_reg('x20');
    my $code = $as->code;
    is length($code), 8, 'push_reg + pop_reg = 8 bytes';
};
subtest 'mov_imm small' => sub {
    my $as = Brocken::Target::Architecture::ARM64::Emit->new;
    $as->mov_imm( 'x0', 0 );
    $as->mov_imm( 'x1', 255 );
    $as->mov_imm( 'x2', 0xFFFF );
    my $code = $as->code;
    is length($code), 12, 'three imm moves = 12 bytes';
};
subtest 'mov_imm large (multi-part)' => sub {
    my $as = Brocken::Target::Architecture::ARM64::Emit->new;
    $as->mov_imm( 'x3', 0xABCDEF12 );
    my $code = $as->code;
    ok length($code) >= 4,  'large imm produces code';
    ok length($code) <= 16, 'large imm within reasonable size';
};
subtest 'mov_reg' => sub {
    my $as = Brocken::Target::Architecture::ARM64::Emit->new;
    $as->mov_reg( 'x10', 'x11' );
    my $code = $as->code;
    is length($code), 4, 'mov_reg is 4 bytes';
};
subtest 'Arithmetic immediate' => sub {
    my $as = Brocken::Target::Architecture::ARM64::Emit->new;
    $as->add_imm( 'sp', 16 );
    $as->sub_imm( 'sp', 32 );
    $as->cmp_reg_imm( 'x0', 0 );
    my $code = $as->code;
    is length($code), 12, 'three immediate ops = 12 bytes';
};
subtest 'Arithmetic register (3-operand)' => sub {
    my $as = Brocken::Target::Architecture::ARM64::Emit->new;
    $as->add_reg( 'x0', 'x1', 'x2' );
    $as->sub_reg( 'x3', 'x4', 'x5' );
    $as->mul_reg( 'x6', 'x7', 'x8' );
    $as->sdiv_reg( 'x9', 'x10', 'x11' );
    $as->and_reg( 'x12', 'x13', 'x14' );
    $as->or_reg( 'x15', 'x16', 'x17' );
    $as->xor_reg( 'x0', 'x1', 'x2' );
    my $code = $as->code;
    is length($code), 28, 'seven 3-op reg = 28 bytes';
};
subtest 'Shift operations' => sub {
    my $as = Brocken::Target::Architecture::ARM64::Emit->new;
    $as->lsl_imm( 'x0', 'x1', 3 );
    $as->lsr_imm( 'x2', 'x3', 5 );
    my $code = $as->code;
    is length($code), 8, 'two shift ops = 8 bytes';
};
subtest 'Comparison' => sub {
    my $as = Brocken::Target::Architecture::ARM64::Emit->new;
    $as->cmp_reg_reg( 'x0', 'x1' );
    $as->test_reg_reg( 'x2', 'x2' );
    $as->cmp_reg_imm( 'x3', 100 );
    $as->setcc( 0, 'x0' );
    my $code = $as->code;
    ok length($code) > 0, 'comparison ops produce code';
};
subtest 'Memory operations' => sub {
    my $as = Brocken::Target::Architecture::ARM64::Emit->new;
    $as->load_reg_mem( 'x0', 'x19', 0 );
    $as->store_mem_disp_reg( 'x19', 8, 'x1' );
    $as->load_reg_mem_byte( 'x2', 'x20', 4 );
    $as->store_mem_disp_byte( 'x20', 12, 'x3' );
    $as->ldur_reg_mem( 'x4', 'x21', -8 );
    $as->stur_mem_disp_reg( 'x21', -16, 'x5' );
    my $code = $as->code;
    ok length($code) > 0, 'memory ops produce code';
    is length($code), 24, 'six memory ops = 24 bytes';
};
subtest 'Atomic (load-link/store-conditional)' => sub {
    my $as = Brocken::Target::Architecture::ARM64::Emit->new;
    $as->ldxr_reg( 'x0', 'x1' );
    $as->stxr_reg( 'x2', 'x3', 'x4' );
    my $code = $as->code;
    is length($code), 8, 'two atomic ops = 8 bytes';
};
subtest 'Floating point ops' => sub {
    my $as = Brocken::Target::Architecture::ARM64::Emit->new;
    $as->fadd_reg( 'd0', 'd1', 'd2' );
    $as->fsub_reg( 'd3', 'd4', 'd5' );
    $as->fmul_reg( 'd6', 'd7', 'd8' );
    $as->fmov_reg( 'd9', 'd10' );
    $as->fcmp_reg( 'd11', 'd12' );
    $as->fmov_x_to_d( 'd13', 'x14' );
    $as->fmov_d_to_x( 'x15', 'd0' );
    $as->ldr_d_mem( 'd1', 'x0', 0 );
    $as->str_d_mem( 'd2', 'x1', 8 );
    my $code = $as->code;
    ok length($code) > 0, 'float ops produce code';
    is length($code), 36, 'nine float ops = 36 bytes';
};
subtest 'Control flow' => sub {
    my $as = Brocken::Target::Architecture::ARM64::Emit->new;
    $as->mark_label('L_start');
    $as->mark_label('L_mid');
    $as->jmp('L_end');
    $as->call_label('L_func');
    $as->jcc( 0, 'L_cond' );
    $as->cbnz_label( 'x0', 'L_loop' );
    my $code = $as->code;
    ok length($code) > 0, 'control flow produces code';
};
subtest 'resolve fixups' => sub {
    my $as = Brocken::Target::Architecture::ARM64::Emit->new;
    $as->mark_label('L_func');
    $as->mov_imm( 'x0', 42 );
    $as->mark_label('L_after');
    $as->jmp('L_func');
    $as->call_label('L_func');
    $as->jcc( 0, 'L_func' );
    $as->resolve( 0, 0 );
    my $code = $as->code;
    ok length($code) > 0, 'resolved code produced';
};
subtest 'unresolved label dies' => sub {
    my $as = Brocken::Target::Architecture::ARM64::Emit->new;
    $as->jmp('L_nonexistent');
    ok dies { $as->resolve( 0, 0 ) }, 'unresolved label throws error';
};
subtest 'lea_rva fixup' => sub {
    my $as = Brocken::Target::Architecture::ARM64::Emit->new;
    $as->lea_rva( 'x0', 'DATA:0' );
    $as->lea_rva( 'x1', 'L_label' );
    $as->mark_label('L_label');
    $as->resolve( 0, 0x2000 );
    my $code = $as->code;
    ok length($code) >= 8, 'lea_rva produces code with fixup';
};
subtest 'syscall' => sub {
    my $as = Brocken::Target::Architecture::ARM64::Emit->new;
    $as->syscall();
    is unpack( 'H*', $as->code ), '010000d4', 'syscall encoding (LE)';
};
done_testing;
