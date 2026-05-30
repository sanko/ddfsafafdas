use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
use Brocken::Core::IR::Builder;
subtest 'Basic IR Construction' => sub {
    my $b  = Brocken::Core::IR::Builder->new;
    my $v1 = $b->emit( 'constant', 'Int', [42] );
    like $v1, qr/^%\d+$/, 'new_reg auto-generated';
    my $insts = $b->instructions;
    is scalar(@$insts),      1,          'one instruction';
    is $insts->[0]{op},      'constant', 'op is constant';
    is $insts->[0]{type},    'Int',      'type is Int';
    is $insts->[0]{args}[0], 42,         'args[0] is 42';
    is $insts->[0]{dest},    $v1,        'dest is the vreg';
};
subtest 'emit with explicit dest' => sub {
    my $b  = Brocken::Core::IR::Builder->new;
    my $v1 = $b->emit( 'constant', 'Int', [10], '%custom' );
    is $v1,                         '%custom', 'explicit dest returned';
    is $b->instructions->[0]{dest}, '%custom', 'explicit dest stored';
};
subtest 'emit void type (no dest)' => sub {
    my $b   = Brocken::Core::IR::Builder->new;
    my $res = $b->emit( 'leave_func', 'void', ['%1'] );
    is $res, undef, 'void emit returns undef';
    ok !defined( $b->instructions->[0]{dest} ), 'void instruction has no dest';
};
subtest 'Register allocation' => sub {
    my $b = Brocken::Core::IR::Builder->new;
    my @regs;
    for ( 1 .. 5 ) { push @regs, $b->new_reg }
    is $regs[0], '%1', 'registers start at %1';
    is $regs[4], '%5', 'registers end at %5';
};
subtest 'Label allocation' => sub {
    my $b = Brocken::Core::IR::Builder->new;
    my @labels;
    for ( 1 .. 3 ) { push @labels, $b->new_label }
    is $labels[0], 'L1', 'labels start at L1';
    is $labels[2], 'L3', 'labels end at L3';
};
subtest 'emit_label' => sub {
    my $b = Brocken::Core::IR::Builder->new;
    $b->emit_label('L_loop');
    my $inst = $b->instructions->[0];
    is $inst->{op},   'label',  'label op';
    is $inst->{name}, 'L_loop', 'label name';
};
subtest 'emit_jump' => sub {
    my $b = Brocken::Core::IR::Builder->new;
    $b->emit_jump('L_exit');
    my $inst = $b->instructions->[0];
    is $inst->{op},     'jmp',    'jmp op';
    is $inst->{target}, 'L_exit', 'jmp target';
};
subtest 'emit_cond_br' => sub {
    my $b = Brocken::Core::IR::Builder->new;
    $b->emit_cond_br( '%1', 'L_true', 'L_false' );
    my $inst = $b->instructions->[0];
    is $inst->{op},      'cond_br', 'cond_br op';
    is $inst->{reg},     '%1',      'cond_br reg';
    is $inst->{true_l},  'L_true',  'cond_br true label';
    is $inst->{false_l}, 'L_false', 'cond_br false label';
};
subtest 'push/pop instructions' => sub {
    my $b = Brocken::Core::IR::Builder->new;
    $b->emit( 'constant', 'Int', [1] );
    $b->emit( 'constant', 'Int', [2] );
    is scalar( @{ $b->instructions } ), 2, 'two instructions pushed';
    my $popped = $b->pop_instruction;
    is $popped->{args}[0],              2, 'pop returns last instruction';
    is scalar( @{ $b->instructions } ), 1, 'one instruction after pop';
    is $b->last_instruction->{args}[0], 1, 'last_instruction returns top';
};
subtest 'set_instructions replaces all' => sub {
    my $b = Brocken::Core::IR::Builder->new;
    $b->set_instructions( { op => 'custom', type => 'void' } );
    is scalar( @{ $b->instructions } ), 1,        'one instruction after set';
    is $b->instructions->[0]{op},       'custom', 'custom op';
};
subtest 'multiple instruction sequence' => sub {
    my $b  = Brocken::Core::IR::Builder->new;
    my $c1 = $b->emit( 'constant', 'Int', [10] );
    my $c2 = $b->emit( 'constant', 'Int', [20] );
    my $r  = $b->emit( 'add',      'Int', [ $c1, $c2 ] );
    $b->emit( 'leave_func', 'void', [$r] );
    my $insts = $b->instructions;
    is scalar(@$insts),      4,            '4 instructions';
    is $insts->[0]{op},      'constant',   'first: constant';
    is $insts->[1]{op},      'constant',   'second: constant';
    is $insts->[2]{op},      'add',        'third: add';
    is $insts->[3]{op},      'leave_func', 'fourth: leave_func';
    is $insts->[2]{args}[0], $c1,          'add arg1';
    is $insts->[2]{args}[1], $c2,          'add arg2';
    is $insts->[2]{dest},    $r,           'add dest';
};
done_testing;
