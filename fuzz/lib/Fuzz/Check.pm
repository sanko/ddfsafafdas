package Fuzz::Check;
use v5.40;
use strict;
use warnings;
use Exporter 'import';
our @EXPORT_OK = qw(check_ir is_well_formed check_lowering check_ir_properties);

# --- IR Well-Formedness Checks ---
sub check_ir {
    my ($ir) = @_;
    my @errors;
    push @errors, check_label_refs($ir);
    push @errors, check_balanced_pairs($ir);
    push @errors, check_stack_height($ir);
    push @errors, check_op_types($ir);
    push @errors, check_reachable($ir);
    push @errors, check_dest_uniqueness($ir);
    return @errors ? \@errors : undef;
}

sub is_well_formed {
    my ($ir) = @_;
    my $errors = check_ir($ir);
    return !defined($errors) || @$errors == 0;
}

# 1. All jump targets reference existing labels
sub check_label_refs {
    my ($ir) = @_;
    my @errors;
    my %labels;
    for my $i ( 0 .. $#$ir ) {
        my $inst = $ir->[$i];
        $labels{ $inst->{name} } = $i if $inst->{op} eq 'label';
    }
    for my $i ( 0 .. $#$ir ) {
        my $inst = $ir->[$i];
        if ( $inst->{op} eq 'jmp' && !exists $labels{ $inst->{target} } ) {
            push @errors, "L$i: jmp to unknown label '$inst->{target}'";
        }
        if ( $inst->{op} eq 'cond_br' ) {
            push @errors, "L$i: cond_br true_l '$inst->{true_l}' not found"   if !exists $labels{ $inst->{true_l} };
            push @errors, "L$i: cond_br false_l '$inst->{false_l}' not found" if !exists $labels{ $inst->{false_l} };
        }
    }
    return @errors;
}

# 2. enter_func/leave_func are balanced within any linear path
sub check_balanced_pairs {
    my ($ir) = @_;
    my @errors;
    my $depth = 0;
    for my $i ( 0 .. $#$ir ) {
        my $inst = $ir->[$i];
        $depth++ if $inst->{op} eq 'enter_func';
        $depth-- if $inst->{op} eq 'leave_func';
        push @errors, "L$i: leave_func without matching enter_func" if $depth < 0;
    }
    push @errors, "Unbalanced: $depth more enter_func than leave_func" if $depth != 0;
    return @errors;
}

# 3. Stack height tracking (shadow_push/shadow_get balance)
sub check_stack_height {
    my ($ir) = @_;
    my @errors;
    my $shadow_depth = 0;
    for my $i ( 0 .. $#$ir ) {
        my $inst = $ir->[$i];
        if ( $inst->{op} eq 'shadow_push' ) { $shadow_depth++; }
        if ( $inst->{op} eq 'shadow_get' )  { $shadow_depth--; }
        push @errors, "L$i: shadow_get without matching shadow_push" if $shadow_depth < 0;
    }
    push @errors, "Shadow stack not empty at end (depth=$shadow_depth)" if $shadow_depth != 0;
    return @errors;
}

# 4. Basic type consistency checks
my %OP_TYPE_RULES = (
    add    => { args => 2, types => [ 'Int', 'Int' ], dest => 'Int' },
    sub    => { args => 2, types => [ 'Int', 'Int' ], dest => 'Int' },
    mul    => { args => 2, types => [ 'Int', 'Int' ], dest => 'Int' },
    div    => { args => 2, types => [ 'Int', 'Int' ], dest => 'Int' },
    mod    => { args => 2, types => [ 'Int', 'Int' ], dest => 'Int' },
    cmp_eq => { args => 2, types => [ 'Int', 'Int' ], dest => 'Int' },
    cmp_ne => { args => 2, types => [ 'Int', 'Int' ], dest => 'Int' },
    cmp_lt => { args => 2, types => [ 'Int', 'Int' ], dest => 'Int' },
    cmp_gt => { args => 2, types => [ 'Int', 'Int' ], dest => 'Int' },
    cmp_le => { args => 2, types => [ 'Int', 'Int' ], dest => 'Int' },
    cmp_ge => { args => 2, types => [ 'Int', 'Int' ], dest => 'Int' },
    and    => { args => 2, types => [ 'Int', 'Int' ], dest => 'Int' },
    or     => { args => 2, types => [ 'Int', 'Int' ], dest => 'Int' },
    shl    => { args => 2, types => [ 'Int', 'Int' ], dest => 'Int' },
    shr    => { args => 2, types => [ 'Int', 'Int' ], dest => 'Int' },
);

sub check_op_types {
    my ($ir) = @_;
    my @errors;
    for my $i ( 0 .. $#$ir ) {
        my $inst = $ir->[$i];
        my $op   = $inst->{op};
        my $rule = $OP_TYPE_RULES{$op};
        next unless $rule;
        my $args = $inst->{args};
        if ( @$args != $rule->{args} ) {
            push @errors, "L$i: $op expects $rule->{args} args, got " . scalar(@$args);
        }
        if ( $inst->{type} && $inst->{type} ne 'void' && !$inst->{dest} ) {
            push @errors, "L$i: $op non-void type '$inst->{type}' but no dest";
        }
    }
    return @errors;
}

# 5. No dead code after unconditional jmp or leave_func
sub check_reachable {
    my ($ir) = @_;
    my @errors;
    my $expect_label = 0;
    for my $i ( 0 .. $#$ir ) {
        my $inst = $ir->[$i];
        if ($expect_label) {
            if ( $inst->{op} ne 'label' ) {
                push @errors, "L$i: unreachable code after jmp/leave_func (expected label)";
            }
            $expect_label = 0;
        }
        $expect_label = 1 if $inst->{op} eq 'jmp' || $inst->{op} eq 'leave_func';
    }
    return @errors;
}

# 6. Dest register uniqueness (no two instructions define the same vreg)
sub check_dest_uniqueness {
    my ($ir) = @_;
    my @errors;
    my %defined;
    for my $i ( 0 .. $#$ir ) {
        my $inst = $ir->[$i];
        my $dest = $inst->{dest};
        next unless $dest && $dest =~ /^%\d+$/;
        if ( exists $defined{$dest} ) {
            push @errors, "L$i: vreg $dest redefined (first at L$defined{$dest})";
        }
        $defined{$dest} = $i;
    }
    return @errors;
}

# --- Lowering-Specific Checks ---
sub check_lowering {
    my ( $ast, $ir ) = @_;
    my @errors;

    # Check that every named function in AST has a corresponding label in IR
    my %ast_funcs;
    _collect_funcs( $ast, \%ast_funcs );
    my %ir_labels;
    for my $inst (@$ir) {
        $ir_labels{ $inst->{name} } = 1 if $inst->{op} eq 'label';
    }
    for my $fname ( keys %ast_funcs ) {
        my $label = "M_$fname";
        if ( !exists $ir_labels{$label} ) {
            push @errors, "AST function '$fname' missing IR label '$label'";
        }
    }
    return @errors ? \@errors : undef;
}

sub _collect_funcs {
    my ( $node, $seen ) = @_;
    return unless ref $node;
    my $cls = ref $node;
    if ( $cls eq 'Brocken::AST::OOP::Method' ) {
        $seen->{ $node->name } = 1;
    }
    if ( $cls eq 'Brocken::AST::OOP::ClassDecl' ) {
        for my $m ( @{ $node->methods } ) {
            $seen->{ $node->name . '::' . $m->name } = 1;
        }
        for my $m ( @{ $node->methods } ) {
            _collect_funcs( $m->body, $seen );
        }
        return;
    }
    if ( $cls eq 'Brocken::AST::Stmt::Block' ) {
        _collect_funcs( $_, $seen ) for @{ $node->statements };
        return;
    }
    if ( $cls eq 'Brocken::AST::Stmt::If' ) {
        _collect_funcs( $node->then_block, $seen );
        _collect_funcs( $node->else_block, $seen ) if $node->else_block;
        return;
    }
    if ( $cls eq 'Brocken::AST::Stmt::While' ) {
        _collect_funcs( $node->body, $seen );
        return;
    }
    if ( $cls eq 'Brocken::AST::OOP::AnonSub' ) {
        _collect_funcs( $node->body, $seen );
        return;
    }
    if ( $cls eq 'Brocken::AST::Async::FiberBlock' ) {
        _collect_funcs( $node->body, $seen );
        return;
    }
}

# --- Property Checks ---
sub check_ir_properties {
    my ($ir) = @_;
    my @props;
    my $total   = scalar @$ir;
    my $labels  = grep { $_->{op} eq 'label' } @$ir;
    my $jumps   = grep { $_->{op} eq 'jmp' } @$ir;
    my $calls   = grep { $_->{op} eq 'call_func' } @$ir;
    my $stores  = grep { $_->{op} =~ /store/ } @$ir;
    my $loads   = grep { $_->{op} =~ /load/ } @$ir;
    my $consts  = grep { $_->{op} eq 'constant' } @$ir;
    my $locals  = grep { $_->{op} =~ /local_/ } @$ir;
    my $intrins = grep { $_->{op} =~ /intrinsic_/ } @$ir;
    push @props, "instructions=$total";
    push @props, "labels=$labels";
    push @props, "jumps=$jumps";
    push @props, "calls=$calls";
    push @props, "stores=$stores";
    push @props, "loads=$loads";
    push @props, "constants=$consts";
    push @props, "locals=$locals";
    push @props, "intrinsics=$intrins";
    return join( ', ', @props );
}
1;
