use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Brocken::AST;

class Brocken::Parser {
    field $tokens : param;
    field $pos = 0;

    # Precedence Table (Higher number = binds tighter)
    my %PRECEDENCE = (
        '='  => 10,                                                              #
        '?'  => 11,                                                              #
        '||' => 12,                                                              #
        '&&' => 13,                                                              #
        '==' => 15, '!=' => 15, '<' => 15, '>' => 15, '<=' => 15, '>=' => 15,    #
        '+'  => 20, '-'  => 20,                                                  #
        '*'  => 30, '/'  => 30,                                                  #
        '['  => 50,                                                              #
        '->' => 60,                                                              #
        '('  => 70,                                                              # Expression calls
    );

    # Statement Registry (Keyword -> Method)
    my %STMT_HANDLERS = (
        'my'     => '_parse_var_decl',
        'state'  => '_parse_state_decl',
        'if'     => '_parse_if',
        'unless' => '_parse_unless',
        'while'  => '_parse_while',
        'until'  => '_parse_until',
        'class'  => '_parse_class',
        'sub'    => '_parse_sub_stmt',
        'defer'  => '_parse_defer',
        'return' => '_parse_return',
        'exit'   => '_parse_exit',
        'say'    => '_parse_builtin_call',
        'print'  => '_parse_builtin_call',
        '{'      => '_parse_block_stmt',
    );

    # Expression Prefix Registry (Starts an expression)
    my %PREFIX_HANDLERS = (
        'NUM'    => '_parse_num_literal',
        'STRING' => '_parse_string_literal',
        'VAR'    => '_parse_var_ref',
        'IDENT'  => '_parse_ident_or_call',
        '['      => '_parse_array_literal',
        '('      => '_parse_grouped_expr',
        '!'      => '_parse_unary_op',
        'true'   => '_parse_bool_literal',
        'false'  => '_parse_bool_literal',
        'sub'    => '_parse_anon_sub',
        'fiber'  => '_parse_fiber',
        'yield'  => '_parse_yield',
        'map'    => '_parse_map',
    );

    # Expression Infix Registry (Connects two expressions)
    my %INFIX_HANDLERS = (
        '+'  => '_parse_bin_op',
        '-'  => '_parse_bin_op',
        '*'  => '_parse_bin_op',
        '/'  => '_parse_bin_op',
        '==' => '_parse_bin_op',
        '!=' => '_parse_bin_op',
        '<'  => '_parse_bin_op',
        '>'  => '_parse_bin_op',
        '<=' => '_parse_bin_op',
        '>=' => '_parse_bin_op',
        '&&' => '_parse_bin_op',
        '||' => '_parse_bin_op',
        '='  => '_parse_bin_op',
        '->' => '_parse_deref',
        '?'  => '_parse_ternary',
    );

    # Core Navigation
    method current() { $tokens->[$pos]       // { type => 'EOF', value => 'EOF' } }
    method peek()    { $tokens->[ $pos + 1 ] // { type => 'EOF', value => 'EOF' } }

    method advance() {
        my $prev = $self->current();
        $pos++;
        return $prev;
    }

    method expect($val) {
        my $tok = $self->current;
        if ( $tok->{value} eq $val || $tok->{type} eq $val ) {
            $self->advance;
            return $tok;
        }
        die sprintf "Parse Error L:%d C:%d: Expected '%s', got '%s'\n", $tok->{line}, $tok->{col}, $val, $tok->{value};
    }

    # --- Main Entry Points ---
    method parse() {
        my @nodes;
        while ( $self->current->{type} ne 'EOF' ) {
            push @nodes, $self->parse_statement();
        }
        return \@nodes;
    }

    method parse_statement() {
        my $val = $self->current->{value};
        if ( my $method = $STMT_HANDLERS{$val} ) {
            return $self->$method();
        }

        # Fallback: Handle $var = expr; as an assignment expression
        my $expr = $self->parse_expression(0);
        $self->expect(';');
        return $expr;
    }

    method parse_expression( $precedence = 0 ) {
        my $tok           = $self->current;
        my $prefix_method = $PREFIX_HANDLERS{ $tok->{value} } // $PREFIX_HANDLERS{ $tok->{type} };
        die "Parse Error L:$tok->{line}: Unexpected token in expression: " . $tok->{value} unless $prefix_method;
        my $left = $self->$prefix_method($tok);
        while ( $precedence < ( $PRECEDENCE{ $self->current->{value} } // 0 ) ) {
            my $op           = $self->current->{value};
            my $infix_method = $INFIX_HANDLERS{$op};
            last unless $infix_method;
            $self->advance();
            $left = $self->$infix_method( $left, $op );
        }
        return $left;
    }

    # --- Statement Handlers ---
    method _parse_var_decl() {
        $self->advance();    # consume 'my'
        my $type = $self->_parse_type_spec();
        my $name = $self->expect('VAR')->{value};
        $self->expect('=');
        my $val = $self->parse_expression(0);
        $self->expect(';');
        return Brocken::AST::Stmt::VarDecl->new( name => $name, type => $type, value => $val );
    }

    method _parse_state_decl() {
        $self->advance();    # consume 'state'
        my $type = $self->_parse_type_spec();
        my $name = $self->expect('VAR')->{value};
        $self->expect('=');
        my $val = $self->parse_expression(0);
        $self->expect(';');
        return Brocken::AST::Stmt::StateDecl->new( name => $name, type => $type, value => $val );
    }

    method _parse_if() {
        $self->advance();    # consume 'if'
        $self->expect('(');
        my $cond = $self->parse_expression(0);
        $self->expect(')');
        my $then = $self->_parse_block_stmt();
        my $else = undef;
        if ( $self->current->{value} eq 'else' ) {
            $self->advance();
            $else = ( $self->current->{value} eq 'if' ) ? $self->_parse_if() : $self->_parse_block_stmt();
        }
        return Brocken::AST::Stmt::If->new( condition => $cond, then_block => $then, else_block => $else );
    }

    method _parse_unless() {
        $self->advance();
        $self->expect('(');
        my $cond = Brocken::AST::Expr::UnaryOp->new( op => '!', expr => $self->parse_expression(0) );
        $self->expect(')');
        return Brocken::AST::Stmt::If->new( condition => $cond, then_block => $self->_parse_block_stmt() );
    }

    method _parse_while() {
        $self->advance();
        $self->expect('(');
        my $cond = $self->parse_expression(0);
        $self->expect(')');
        return Brocken::AST::Stmt::While->new( condition => $cond, body => $self->_parse_block_stmt() );
    }

    method _parse_until() {
        $self->advance();
        $self->expect('(');
        my $cond = Brocken::AST::Expr::UnaryOp->new( op => '!', expr => $self->parse_expression(0) );
        $self->expect(')');
        return Brocken::AST::Stmt::While->new( condition => $cond, body => $self->_parse_block_stmt() );
    }

    method _parse_return() {
        $self->advance();
        my $expr = $self->parse_expression(0);
        $self->expect(';');
        return Brocken::AST::Stmt::Return->new( expr => $expr );
    }

    method _parse_exit() {
        $self->advance();
        my $expr = $self->parse_expression(0);
        $self->expect(';');
        return Brocken::AST::Stmt::Exit->new( expr => $expr );
    }

    method _parse_builtin_call() {
        my $tok  = $self->advance();
        my $name = $tok->{value};
        my $expr = $self->parse_expression(0);
        $self->expect(';');
        return Brocken::AST::Expr::Call->new( name => $name, args => [$expr] );
    }

    method _parse_sub_stmt() {
        $self->advance();    # consume 'sub'
        my $name   = $self->expect('IDENT')->{value};
        my $params = $self->_parse_routine_params();
        my $body   = $self->_parse_block_stmt();
        return Brocken::AST::OOP::Method->new( name => $name, params => $params, body => $body );
    }
    method _parse_defer() {
        $self->advance(); # consume 'defer'
        my $block = $self->_parse_block_stmt();
        return Brocken::AST::Stmt::Defer->new( block => $block );
    }

    method _parse_class() {
        $self->advance();    # consume 'class'
        my $name = $self->expect('IDENT')->{value};
        $self->expect('{');
        my ( @fields, @methods );
        while ( $self->current->{value} ne '}' ) {
            my $v = $self->current->{value};
            if ( $v eq 'field' ) {
                $self->advance();
                my $type  = $self->_parse_type_spec();
                my $fname = $self->expect('VAR')->{value};
                $self->expect(';');
                push @fields, Brocken::AST::OOP::FieldDecl->new( name => $fname, type => $type );
            }
            elsif ( $v eq 'method' ) {
                $self->advance();
                my $mname  = $self->expect('IDENT')->{value};
                my $params = $self->_parse_routine_params();
                push @methods, Brocken::AST::OOP::Method->new( name => $mname, params => $params, body => $self->_parse_block_stmt() );
            }
            else { die "Unexpected token in class $name: " . $self->current->{value}; }
        }
        $self->expect('}');
        return Brocken::AST::OOP::ClassDecl->new( name => $name, fields => \@fields, methods => \@methods );
    }

    method _parse_block_stmt() {
        $self->expect('{');
        my @stmts;
        while ( $self->current->{value} ne '}' ) { push @stmts, $self->parse_statement(); }
        $self->expect('}');
        return Brocken::AST::Stmt::Block->new( statements => \@stmts );
    }

    # --- Expression Prefix Handlers ---
    method _parse_num_literal($tok)    { $self->advance(); Brocken::AST::Expr::Const->new( value => $tok->{value}, type => 'Int' ) }
    method _parse_string_literal($tok) { $self->advance(); Brocken::AST::Expr::Const->new( value => $tok->{value}, type => 'String' ) }
    method _parse_bool_literal($tok)   { $self->advance(); Brocken::AST::Expr::Const->new( value => ( $tok->{value} eq 'true' ? 1 : 0 ), type => 'Int' ) }
    method _parse_var_ref($tok)        { $self->advance(); Brocken::AST::Expr::Var->new( name => $tok->{value} ) }

    method _parse_ident_or_call($tok) {
        my $name = $tok->{value};
        $self->advance();
        if ( $self->current->{value} eq '(' ) {
            return Brocken::AST::Expr::Call->new( name => $name, args => $self->_parse_args() );
        }

        # Treat bare Ident as a Class reference for now
        return Brocken::AST::Expr::Const->new( value => $name, type => 'Class' );
    }

    method _parse_grouped_expr($tok) {
        $self->advance();
        my $expr = $self->parse_expression(0);
        $self->expect(')');
        return $expr;
    }

    method _parse_unary_op($tok) {
        $self->advance();
        return Brocken::AST::Expr::UnaryOp->new( op => $tok->{value}, expr => $self->parse_expression(40) );
    }

    method _parse_array_literal($tok) {
        $self->advance();
        my @el;
        while ( $self->current->{value} ne ']' ) {
            push @el, $self->parse_expression(0);
            last if $self->current->{value} eq ']';
            $self->expect(',');
        }
        $self->expect(']');
        return Brocken::AST::Expr::ArrayLiteral->new( elements => \@el );
    }

    method _parse_anon_sub($tok) {
        $self->advance();
        my $params = $self->_parse_routine_params();
        my $body   = $self->_parse_block_stmt();
        return Brocken::AST::OOP::AnonSub->new( params => $params, body => $body );
    }

    method _parse_fiber($tok) {
        $self->advance();
        my $params = ( $self->current->{value} eq '(' ) ? $self->_parse_routine_params() : [];
        return Brocken::AST::Async::FiberBlock->new( params => $params, body => $self->_parse_block_stmt() );
    }

    method _parse_yield($tok) {
        $self->advance();
        return Brocken::AST::Async::Yield->new( expr => $self->parse_expression(0) );
    }

    method _parse_map($tok) {
        $self->advance();
        $self->expect('{');
        my $expr = $self->parse_expression(0);
        $self->expect('}');

        # map consumes source with relatively low precedence
        return Brocken::AST::Stmt::Map->new( expr => $expr, source => $self->parse_expression(25) );
    }

    # --- Expression Infix Handlers ---
    method _parse_bin_op( $left, $op ) {
        my $p = $PRECEDENCE{$op};

        # Assignment is right-associative (x = y = 10)
        $p-- if $op eq '=';
        my $right = $self->parse_expression($p);

        # If the operator is '=', transform it into an Assignment AST node
        if ( $op eq '=' ) {
            if ( $left isa Brocken::AST::Expr::Var ) {
                return Brocken::AST::Stmt::Assignment->new( name => $left->name, value => $right );
            }


            # For Milestone 3/4: Support $obj->field = val
            # if ($left isa Brocken::AST::OOP::MethodCall) { ... }
            warn ref $left;
            die "Parse Error: Left side of assignment must be a variable";
        }
        return Brocken::AST::Expr::BinOp->new( op => $op, left => $left, right => $right );
    }

    method _parse_ternary( $left, $op ) {
        my $then = $self->parse_expression(0);
        $self->expect(':');
        my $else = $self->parse_expression(0);
        return Brocken::AST::Expr::Ternary->new( cond => $left, then => $then, else => $else );
    }

    method _parse_deref( $left, $op ) {
        if ( $self->current->{value} eq '(' ) {
            return Brocken::AST::Expr::AnonCall->new( invocant => $left, args => $self->_parse_args() );
        }
        my $mname = $self->expect('IDENT')->{value};
        return Brocken::AST::OOP::MethodCall->new( invocant => $left, name => $mname, args => $self->_parse_args() );
    }

    # --- Parameter and Argument Lists ---
    method _parse_routine_params() {
        $self->expect('(');
        my @params;
        while ( $self->current->{value} ne ')' ) {
            my $type = $self->_parse_type_spec();
            push @params, { name => $self->expect('VAR')->{value}, type => $type };
            last if $self->current->{value} eq ')';
            $self->expect(',');
        }
        $self->expect(')');
        return \@params;
    }

    method _parse_args() {
        $self->expect('(');
        my @args;
        while ( $self->current->{value} ne ')' ) {
            push @args, $self->parse_expression(0);
            last if $self->current->{value} eq ')';
            $self->expect(',');
        }
        $self->expect(')');
        return \@args;
    }

    method _parse_type_spec() {
        if ( $self->current->{type} eq 'KEYWORD' && $self->current->{value} =~ /^(?:Int|String|Any|Bool|Class)$/ ) {
            my $t = $self->current->{value};
            $self->advance();
            return $t;
        }
        return 'Any';
    }
}
1;
