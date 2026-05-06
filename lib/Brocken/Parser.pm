    use v5.40;
    use utf8;
    use feature 'class';
    no warnings 'portable', 'experimental::class';

    class Brocken::Parser {
        field $tokens : param;
        field $pos = 0;
        my %PRECEDENCE = (
            '='  => 10,                                                              #
            '?'  => 11,                                                              # Ternary is low
            '||' => 12,                                                              #
            '&&' => 13,                                                              #
            '==' => 15, '!=' => 15, '<' => 15, '>' => 15, '<=' => 15, '>=' => 15,    #
            '+'  => 20, '-'  => 20,                                                  #
            '*'  => 30, '/'  => 30,                                                  #
            '['  => 50, '->' => 60                                                   #
        );
        method current() { return $tokens->[$pos]       // { type => 'EOF', value => 'EOF' }; }
        method peek()    { return $tokens->[ $pos + 1 ] // { type => 'EOF', value => 'EOF' }; }
        method advance() { $pos++; return $self->current(); }

        method expect($expected) {
            my $tok = $self->current();
            if ( $tok->{type} eq $expected || $tok->{value} eq $expected ) { $self->advance(); return $tok; }
            die sprintf "Parse Error L:%d: Expected '%s', got '%s'\n", $tok->{line}, $expected, $tok->{value};
        }

        # Helper for (...) lists in sub/method definitions
        method parse_routine_params() {
            $self->expect('(');
            my @params;
            while ( $self->current->{value} ne ')' ) {
                my $type = 'Any';
                if ( $self->current->{type} eq 'KEYWORD' && $self->current->{value} =~ /^(?:Int|String|Any|Class)$/ ) {
                    $type = $self->current->{value};
                    $self->advance();
                }
                push @params, { name => $self->expect('VAR')->{value}, type => $type };
                last if $self->current->{value} eq ')';
                $self->expect(',');
            }
            $self->expect(')');
            return \@params;
        }

        # Helper for (...) lists in calls
        method parse_args() {
            $self->expect('(');
            my @args;
            while ( $self->current->{value} ne ')' ) {
                push @args, $self->parse_expression();
                last if $self->current->{value} eq ')';
                $self->expect(',');
            }
            $self->expect(')');
            return \@args;
        }

        method parse_expression( $precedence = 0 ) {
            my $tok = $self->current();
            my $left;
            if ( $tok->{value} eq '!' ) {
                $self->advance();
                $left = Brocken::AST::UnaryOp->new( op => '!', expr => $self->parse_expression(40) );
            }
            elsif ( $tok->{value} eq 'true' )  { $left = Brocken::AST::Const->new( value => 1,             type => 'Int' );    $self->advance(); }
            elsif ( $tok->{value} eq 'false' ) { $left = Brocken::AST::Const->new( value => 0,             type => 'Int' );    $self->advance(); }
            elsif ( $tok->{type} eq 'NUM' )    { $left = Brocken::AST::Const->new( value => $tok->{value}, type => 'Int' );    $self->advance(); }
            elsif ( $tok->{type} eq 'STRING' ) { $left = Brocken::AST::Const->new( value => $tok->{value}, type => 'String' ); $self->advance(); }
            elsif ( $tok->{type} eq 'VAR' )    { $left = Brocken::AST::Var->new( name => $tok->{value} ); $self->advance(); }
            elsif ( $tok->{value} eq '[' ) {
                $self->advance();
                my @el;
                while ( $self->current->{value} ne ']' ) {
                    push @el, $self->parse_expression();
                    last if $self->current->{value} eq ']';
                    $self->expect(',');
                }
                $self->expect(']');
                $left = Brocken::AST::ArrayLiteral->new( elements => \@el );
            }
            elsif ( $tok->{value} eq 'sub' ) {
                $self->advance();
                my $params = $self->parse_routine_params();
                my $body   = $self->parse_block();
                $left = Brocken::AST::AnonSub->new( params => $params, body => $body );
            }
            elsif ( $tok->{type} eq 'IDENT' ) {
                if ( $self->peek()->{value} eq '(' ) {
                    my $name = $tok->{value};
                    $self->advance();
                    $left = Brocken::AST::Call->new( name => $name, args => $self->parse_args() );
                }
                else {
                    $left = Brocken::AST::Const->new( value => $tok->{value}, type => 'Class' );
                    $self->advance();
                }
            }
            elsif ( $tok->{value} eq 'map' ) {
                $self->advance();
                $self->expect('{');
                my $expr = $self->parse_expression();
                $self->expect('}');
                $left = Brocken::AST::Map->new( expr => $expr, source => $self->parse_expression(25) );
            }
            elsif ( $tok->{value} eq 'fiber' ) {
                $self->advance();
                my $params = [];
                if ( $self->current->{value} eq '(' ) {
                    $params = $self->parse_routine_params();
                }
                $left = Brocken::AST::FiberBlock->new( params => $params, body => $self->parse_block() );
            }
            elsif ( $tok->{value} eq 'yield' ) {
                $self->advance();
                $left = Brocken::AST::Yield->new( expr => $self->parse_expression(0) );
            }
            else { die "Unexpected token in expr: $tok->{value} at L:$tok->{line}\n"; }
            while ( $precedence < ( $PRECEDENCE{ $self->current->{value} } // 0 ) ) {
                my $op = $self->current->{value};
                $self->advance();
                if ( $op eq '?' ) {
                    my $then = $self->parse_expression(0);
                    $self->expect(':');
                    my $else = $self->parse_expression(0);
                    $left = Brocken::AST::Ternary->new( cond => $left, then => $then, else => $else );
                }
                elsif ( $op eq '->' ) {
                    if ( $self->current->{value} eq '(' ) {

                        # Anonymous call: $fn->()
                        $left = Brocken::AST::AnonCall->new( invocant => $left, args => $self->parse_args() );
                    }
                    else {
                        # Method call: $obj->name()
                        my $mname = $self->expect('IDENT')->{value};
                        $left = Brocken::AST::MethodCall->new( invocant => $left, name => $mname, args => $self->parse_args() );
                    }
                }
                else {
                    $left = Brocken::AST::BinOp->new( op => $op, left => $left, right => $self->parse_expression( $PRECEDENCE{$op} ) );
                }
            }
            return $left;
        }

        method parse_statement() {
            my $tok = $self->current();
            if ( $tok->{value} eq '{' ) { return $self->parse_block(); }
            if ( $tok->{value} eq 'class' ) {
                $self->advance();
                my $name = $self->expect('IDENT')->{value};
                $self->expect('{');
                my ( @fields, @methods );
                while ( $self->current->{value} ne '}' ) {
                    if ( $self->current->{value} eq 'field' ) {
                        $self->advance();
                        my $type = 'Any';
                        if ( $self->current->{type} eq 'KEYWORD' ) { $type = $self->current->{value}; $self->advance(); }
                        my $fname = $self->expect('VAR')->{value};
                        $self->expect(';');
                        push @fields, Brocken::AST::FieldDecl->new( name => $fname, type => $type );
                    }
                    elsif ( $self->current->{value} eq 'method' ) {
                        $self->advance();
                        my $mname  = $self->expect('IDENT')->{value};
                        my $params = $self->parse_routine_params();
                        push @methods, Brocken::AST::Method->new( name => $mname, params => $params, body => $self->parse_block() );
                    }
                    else { die "Parse Error: Unexpected token in class $name: " . $self->current->{value} . "\n"; }
                }
                $self->expect('}');
                return Brocken::AST::ClassDecl->new( name => $name, fields => \@fields, methods => \@methods );
            }
            if ( $tok->{value} eq 'sub' ) {
                $self->advance();
                my $name   = $self->expect('IDENT')->{value};
                my $params = $self->parse_routine_params();
                return Brocken::AST::Method->new( name => $name, params => $params, body => $self->parse_block() );
            }
            if ( $tok->{value} eq 'my' || $tok->{value} eq 'state' ) {
                my $is_state = ( $tok->{value} eq 'state' );
                $self->advance();
                my $type = 'Any';
                if ( $self->current()->{type} eq 'KEYWORD' ) { $type = $self->current()->{value}; $self->advance(); }
                my $var_tok = $self->expect('VAR');
                $self->expect('=');
                my $expr = $self->parse_expression();
                $self->expect(';');
                return $is_state ? Brocken::AST::StateDecl->new( name => $var_tok->{value}, type => $type, value => $expr ) :
                    Brocken::AST::VarDecl->new( name => $var_tok->{value}, type => $type, value => $expr );
            }
            if ( $tok->{type} eq 'VAR' && $self->peek()->{value} eq '=' ) {
                my $name = $tok->{value};
                $self->advance();
                $self->expect('=');
                my $expr = $self->parse_expression();
                $self->expect(';');
                return Brocken::AST::Assignment->new( name => $name, value => $expr );
            }
            if ( $tok->{value} =~ /^(return|exit)$/ ) {
                my $type = $tok->{value};
                $self->advance();
                my $expr = $self->parse_expression();
                $self->expect(';');
                return $type eq 'return' ? Brocken::AST::Return->new( expr => $expr ) : Brocken::AST::Exit->new( expr => $expr );
            }
            if ( $tok->{value} =~ /^(print|say)$/ ) {
                my $name = $tok->{value};
                $self->advance();
                my $expr = $self->parse_expression();
                $self->expect(';');
                return Brocken::AST::Call->new( name => $name, args => [$expr] );
            }
            if ( $tok->{value} eq 'if' ) {
                $self->advance();
                $self->expect('(');
                my $cond = $self->parse_expression();
                $self->expect(')');
                my $then = $self->parse_block();
                my $else = undef;
                if ( $self->current->{value} eq 'else' ) {
                    $self->advance();
                    $else = ( $self->current->{value} eq 'if' ) ? $self->parse_statement() : $self->parse_block();
                }
                return Brocken::AST::If->new( condition => $cond, then_block => $then, else_block => $else );
            }
            if ( $tok->{value} eq 'unless' ) {
                $self->advance();
                $self->expect('(');
                my $cond = Brocken::AST::UnaryOp->new( op => '!', expr => $self->parse_expression() );
                $self->expect(')');
                return Brocken::AST::If->new( condition => $cond, then_block => $self->parse_block() );
            }
            if ( $tok->{value} eq 'until' ) {
                $self->advance();
                $self->expect('(');
                my $cond = Brocken::AST::UnaryOp->new( op => '!', expr => $self->parse_expression() );
                $self->expect(')');
                return Brocken::AST::While->new( condition => $cond, body => $self->parse_block() );
            }
            if ( $tok->{value} eq 'while' ) {
                $self->advance();
                $self->expect('(');
                my $cond = $self->parse_expression();
                $self->expect(')');
                return Brocken::AST::While->new( condition => $cond, body => $self->parse_block() );
            }
            if ( $tok->{value} eq 'method' ) {
                die "Parse Error L:$tok->{line}: 'method' is only allowed inside 'class' blocks. Use 'sub' for global functions.\n";
            }
            my $expr = $self->parse_expression();
            $self->expect(';');
            return $expr;
        }

        method parse_block() {
            $self->expect('{');
            my @stmts;
            while ( $self->current()->{value} ne '}' ) { push @stmts, $self->parse_statement(); }
            $self->expect('}');
            return Brocken::AST::Block->new( statements => \@stmts );
        }

        method parse() {
            my @nodes;
            while ( $self->current()->{type} ne 'EOF' ) { push @nodes, $self->parse_statement(); }
            return \@nodes;
        }
    }
    1;
