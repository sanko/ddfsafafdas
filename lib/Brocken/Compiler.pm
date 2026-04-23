package Brocken::Compiler {
    use v5.40;
    use utf8;
    use feature 'class';
    no warnings 'portable', 'experimental::class';

    class Brocken::Compiler::Lowering {
        use constant { TAG_INT => 0, TAG_STR => 1, TAG_ARR => 2, TAG_OBJ => 3 };
        field $builder : reader : param = Brocken::IR::Builder->new();
        field $data_segment : param;
        field $current_scope = Brocken::Scope->new();
        #
        #~ method enter_scope() { $current_scope = Brocken::Scope->new( parent => $current_scope ); }
        #~ method exit_scope()  { $current_scope = $current_scope->parent; }
        method lower_program($nodes) {
            my @methods = grep { $_ isa Brocken::AST::Method } @$nodes;
            my @stmts   = grep { !( $_ isa Brocken::AST::Method ) } @$nodes;
            $builder->emit_jump('L_MAIN_START');
            for my $m (@methods) {
                $builder->emit_label( "M_" . $m->name );
                $builder->emit( 'enter_func', 'void', [] );
                $current_scope = Brocken::Scope->new( parent => $current_scope );
                my $arg_idx = 0;
                for my $p ( @{ $m->params } ) {
                    my $reg = $builder->emit( 'get_arg', 'i64', [ $arg_idx++ ] );
                    $current_scope->define( $p->{name}, $p->{type} )->ssa_reg($reg);
                }
                $self->lower_block( $m->body->statements );
                $current_scope = $current_scope->parent;
            }
            $builder->emit_label('L_MAIN_START');
            $builder->emit( 'enter_func', 'void', [] );
            $self->lower_block( \@stmts );
            $builder->emit( 'exit_program', 'void', [0] );
        }

        method lower_block($statements) {
            my ( $reg, $type );
            for my $stmt (@$statements) {
                ( $reg, $type ) = $self->lower($stmt);
            }
            return ( $reg, $type );
        }

        method lower($node) {
            if ( $node isa Brocken::AST::Block ) {
                $current_scope = Brocken::Scope->new( parent => $current_scope );
                my @res = $self->lower_block( $node->statements );
                $current_scope = $current_scope->parent;
                return @res;
            }
            if ( $node isa Brocken::AST::Const ) {
                if ( $node->type eq 'String' ) {
                    my $reg = $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string( $node->value ) ] );

                    # Strings are pointers! Milestone 2: Push to shadow stack
                    $builder->emit( 'shadow_push', 'void', [$reg] );
                    return ( $reg, 'String' );
                }
                my $reg = $builder->emit( 'constant', 'i64', [ $node->value ] );
                return ( $reg, 'Int' );
            }
            if ( $node isa Brocken::AST::Var ) {
                my $sym = $current_scope->resolve( $node->name ) // die "Semantic Error: Undeclared " . $node->name . "\n";
                return ( $sym->ssa_reg, $sym->type );
            }
            if ( $node isa Brocken::AST::VarDecl ) {
                my ( $val_reg, $val_type ) = $self->lower( $node->value );
                my $sym = $current_scope->define( $node->name, $node->type );
                if ( $node->type eq 'Any' ) {

                    # BOXING: Convert specific type to 'Any' (Fat Value logic)
                    # For now, we store the payload in ssa_reg.
                    # In full M2, we will store (Tag, Payload)
                    my $var_reg = $builder->new_reg();
                    $builder->emit( 'mov', 'i64', [$val_reg], $var_reg );
                    $sym->ssa_reg($var_reg);
                    return ( $var_reg, 'Any' );
                }
                else {
                    my $var_reg = $builder->new_reg();
                    $builder->emit( 'mov', 'i64', [$val_reg], $var_reg );
                    $sym->ssa_reg($var_reg);
                    return ( $var_reg, $node->type );
                }
            }
            if ( $node isa Brocken::AST::BinOp ) {
                my ( $l_reg, $l_type ) = $self->lower( $node->left );
                my ( $r_reg, $r_type ) = $self->lower( $node->right );

                # Simple Int Math
                my $op_map   = { '+' => 'add', '-' => 'sub', '*' => 'mul', '==' => 'cmp_eq', '!=' => 'cmp_ne', '<' => 'cmp_lt', '>' => 'cmp_gt' };
                my $op       = $op_map->{ $node->op } // die "Unknown op: " . $node->op;
                my $res_type = ( $node->op =~ /[<>=!]/ ) ? 'Int' : 'Int';
                my $reg      = $builder->emit( $op, 'i64', [ $l_reg, $r_reg ] );
                return ( $reg, $res_type );
            }
            if ( $node isa Brocken::AST::Call ) {
                if ( $node->name =~ /^(say|print)$/ ) {
                    my ( $reg, $type ) = $self->lower( $node->args->[0] );

                    # Dynamic dispatch based on lowered type
                    if ( $type eq 'Int' ) {
                        $builder->emit( 'builtin_print_int', 'void', [$reg] );
                    }
                    else {
                        $builder->emit( 'builtin_print', 'void', [$reg] );
                    }
                    if ( $node->name eq 'say' ) {
                        my $nl_reg = $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string("\n") ] );
                        $builder->emit( 'builtin_print', 'void', [$nl_reg] );
                    }
                    return ( undef, 'void' );
                }
                my @arg_regs;
                for my $arg ( @{ $node->args } ) {
                    my ( $r, $t ) = $self->lower($arg);
                    push @arg_regs, $r;
                }
                my $res = $builder->emit( 'call_func', 'i64', [ "M_" . $node->name, @arg_regs ] );
                return ( $res, 'Int' );
            }
            if ( $node isa Brocken::AST::Return ) {
                my ( $reg, $type ) = $self->lower( $node->expr );
                $builder->emit( 'leave_func', 'void', [$reg] );
                return ( undef, 'void' );
            }
            if ( $node isa Brocken::AST::Assignment ) {
                my ( $val_reg, $val_type ) = $self->lower( $node->value );
                my $sym = $current_scope->resolve( $node->name ) // die "Assignment to undeclared " . $node->name . "\n";

                # In Brocken, we keep the register associated with the symbol
                my $var_reg = $sym->ssa_reg;
                $builder->emit( 'mov', 'i64', [$val_reg], $var_reg );

                # If we are assigning a pointer into an 'Any' or 'Array/String' var,
                # the GC needs to know.
                if ( $sym->type =~ /^(Any|String|Array)$/ ) {
                    $builder->emit( 'shadow_push', 'void', [$var_reg] );
                }
                return ( $var_reg, $sym->type );
            }
            if ( $node isa Brocken::AST::Call ) {

                # Builtins
                if ( $node->name =~ /^(say|print)$/ ) {
                    my ( $reg, $type ) = $self->lower( $node->args->[0] );

                    # Branching logic for Int vs String/Any
                    if ( $type eq 'Int' ) {
                        $builder->emit( 'builtin_print_int', 'void', [$reg] );
                    }
                    else {
                        $builder->emit( 'builtin_print', 'void', [$reg] );
                    }
                    if ( $node->name eq 'say' ) {
                        my $nl_reg = $builder->emit( 'load_data_addr', 'ptr', [ $data_segment->add_string("\n") ] );
                        $builder->emit( 'builtin_print', 'void', [$nl_reg] );
                    }
                    return ( undef, 'void' );
                }

                # Standard Method Calls
                my @arg_regs;
                for my $arg ( @{ $node->args } ) {
                    my ( $r, $t ) = $self->lower($arg);
                    push @arg_regs, $r;
                }

                # Emit Call
                my $ret_reg = $builder->emit( 'call_func', 'i64', [ "M_" . $node->name, @arg_regs ] );

                # If the return might be a pointer, we'd shadow_push here too.
                return ( $ret_reg, 'Int' );    # Placeholder: methods return Int for now
            }
            if ( $node isa Brocken::AST::If ) {
                my $l_then = $builder->new_label();
                my $l_else = $builder->new_label();
                my $l_end  = $builder->new_label();
                my ( $cond_reg, $cond_type ) = $self->lower( $node->condition );
                $builder->emit_cond_br( $cond_reg, $l_then, $l_else );
                $builder->emit_label($l_then);
                $self->lower( $node->then_block );
                $builder->emit_jump($l_end);
                $builder->emit_label($l_else);

                if ( $node->else_block ) {
                    $self->lower( $node->else_block );
                }
                $builder->emit_jump($l_end);
                $builder->emit_label($l_end);
                return ( undef, 'void' );
            }
            if ( $node isa Brocken::AST::While ) {
                my $l_start = $builder->new_label();
                my $l_body  = $builder->new_label();
                my $l_end   = $builder->new_label();
                $builder->emit_label($l_start);
                my ( $cond_reg, $cond_type ) = $self->lower( $node->condition );
                $builder->emit_cond_br( $cond_reg, $l_body, $l_end );
                $builder->emit_label($l_body);
                $self->lower( $node->body );    # Blocks handle their own scope
                $builder->emit_jump($l_start);
                $builder->emit_label($l_end);
                return ( undef, 'void' );
            }
            if ( $node isa Brocken::AST::Map ) {
                my ( $src_reg, $src_type ) = $self->lower( $node->source );

                # Emit the map operation.
                # If the Optimizer doesn't fuse this, the Codegen will emit a standard loop.
                my $res_reg = $builder->emit( 'map_op', 'Array', [ $src_reg, $node->expr ] );

                # Results of map are arrays (pointers), so they go to the shadow stack.
                $builder->emit( 'shadow_push', 'void', [$res_reg] );
                return ( $res_reg, 'Array' );
            }
            if ( $node isa Brocken::AST::ArrayLiteral ) {
                my @el_data;
                for my $el ( @{ $node->elements } ) {
                    my ( $r, $t ) = $self->lower($el);
                    push @el_data, { reg => $r, type => $t };
                }
                my $count = scalar @el_data;

                # Brocken Array Header: [ByteSize (8)] [Char/Elem Count (8)] [Flags (8)] ... Data
                my $size = 24 + ( $count * 8 );

                # 1. Allocate from the Isolate's Heap
                my $arr_ptr = $builder->emit( 'alloc_heap', 'ptr', [$size] );

                # 2. Track this pointer in the Shadow Stack immediately!
                $builder->emit( 'shadow_push', 'void', [$arr_ptr] );

                # 3. Initialize Header
                my $c_reg = $builder->emit( 'constant', 'i64', [$count] );
                $builder->emit( 'store_mem_disp', 'void', [ $arr_ptr, 0, $c_reg ] );    # Size
                $builder->emit( 'store_mem_disp', 'void', [ $arr_ptr, 8, $c_reg ] );    # Count

                # 4. Store Elements
                for ( my $i = 0; $i < $count; $i++ ) {
                    $builder->emit( 'store_mem_disp', 'void', [ $arr_ptr, 24 + ( $i * 8 ), $el_data[$i]{reg} ] );
                }
                return ( $arr_ptr, 'Array' );
            }
            return ( undef, 'void' );
        }
    }

    class Brocken::Compiler::Optimizer {

        method optimize($builder) {
            my @instructions = $builder->instructions();
            my $changed      = 1;
            while ($changed) {
                $changed = 0;
                my %def;
                my %use_count;
                my %shadow_push_inst;    # Map register to its shadow_push instruction

                # 1. First Pass: Analyze definitions and use counts
                for my $i (@instructions) {
                    $def{ $i->{dest} } = $i if defined $i->{dest};

                    # Track usages in args
                    if ( defined $i->{args} ) {
                        for my $arg ( @{ $i->{args} } ) {
                            $use_count{$arg}++ if defined $arg && !ref($arg) && $arg =~ /^%/;
                        }
                    }

                    # IMPORTANT: Track usages in cond_br (previously missing!)
                    if ( $i->{op} eq 'cond_br' && $i->{reg} ) {
                        $use_count{ $i->{reg} }++;
                    }

                    # Track shadow_push metadata
                    if ( $i->{op} eq 'shadow_push' ) {
                        $shadow_push_inst{ $i->{args}[0] } = $i;
                    }
                }

                # 2. Second Pass: Perform Fusion
                for my $i (@instructions) {
                    if ( $i->{op} eq 'map_op' ) {
                        my $src_reg  = $i->{args}[0];
                        my $def_inst = $def{$src_reg};
                        if ( $def_inst && $def_inst->{op} eq 'map_op' ) {
                            my $count = $use_count{$src_reg} // 0;

                            # FUSION CONDITION:
                            # Register is used only by the next map,
                            # OR it's used by the next map AND a shadow_push (which we can delete).
                            my $has_shadow = exists $shadow_push_inst{$src_reg};
                            if ( $count == 1 || ( $count == 2 && $has_shadow ) ) {

                                # Merge ASTs: replace $_ in current map with inner map's expression
                                my $fused_ast = $self->substitute_ast( $i->{args}[1], '$_', $def_inst->{args}[1] );

                                # Update current instruction to point to the inner map's source
                                $i->{args}[0] = $def_inst->{args}[0];
                                $i->{args}[1] = $fused_ast;

                                # Nop out the instructions that are no longer needed
                                $def_inst->{op} = 'nop';
                                if ($has_shadow) {
                                    $shadow_push_inst{$src_reg}->{op} = 'nop';
                                }
                                $changed = 1;
                            }
                        }
                    }
                }

                # Cleanup nops
                @instructions = grep { $_->{op} ne 'nop' } @instructions;
            }
            $builder->set_instructions(@instructions);
        }

        method substitute_ast( $node, $var_name, $repl_node ) {
            if ( $node isa Brocken::AST::Var ) {
                return $node->name eq $var_name ? $repl_node : $node;
            }
            if ( $node isa Brocken::AST::BinOp ) {
                return Brocken::AST::BinOp->new(
                    op    => $node->op,
                    left  => $self->substitute_ast( $node->left,  $var_name, $repl_node ),
                    right => $self->substitute_ast( $node->right, $var_name, $repl_node )
                );
            }
            if ( $node isa Brocken::AST::Const ) { return $node; }

            # If we encounter something more complex, we stop and die to prevent silent corruption
            die "Optimizer Error: Unhandled AST node " . ref($node) . " in map closure during fusion.";
        }
    }
};
1;
