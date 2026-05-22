use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Brocken::AST;
use Brocken::Type;

class Brocken::Parser {
    field $tokens : param;
    field $pos = 0;

    # Precedence Table (Higher number = binds tighter)
    my %PRECEDENCE = (
        '='  => 10,                                                                 #
        '?'  => 11,                                                                 #
        '||' => 12, '//' => 12,                                                     #
        '&&' => 13,                                                                 #
        '..' => 17, '...' => 17,                                                    # Range ops
        '==' => 15, '!='  => 15, '<'  => 15, '>'  => 15, '<=' => 15, '>=' => 15,    # Numeric ops
        'eq' => 15, 'ne'  => 15, 'lt' => 15, 'gt' => 15, 'le' => 15, 'ge' => 15,    # String ops
        '+'  => 20, '-'   => 20, '.'  => 20,                                        #
        '*'  => 30, '/'   => 30, '%'  => 30,                                        #
        '['  => 50, '{'   => 50,                                                    # Indexing
        '->' => 60,                                                                 #
        '('  => 70,                                                                 # Expression calls
    );

    # Statement Registry (Keyword -> Method)
    my %STMT_HANDLERS = (
        'my'        => '_parse_var_decl',
        'our'       => '_parse_our_decl',
        'state'     => '_parse_state_decl',
        'if'        => '_parse_if',
        'unless'    => '_parse_unless',
        'while'     => '_parse_while',
        'until'     => '_parse_until',
        'for'       => '_parse_for',
        'next'      => '_parse_next_last_redo',
        'last'      => '_parse_next_last_redo',
        'redo'      => '_parse_next_last_redo',
        'class'     => '_parse_class',
        'sub'       => '_parse_sub_stmt',
        'defer'     => '_parse_defer',
        'use'       => '_parse_use',
        'require'   => '_parse_require',
        'native'    => '_parse_native_decl',
        'eval'      => '_parse_eval',
        'try'       => '_parse_try_catch',
        'die'       => '_parse_die',
        'return'    => '_parse_return',
        'exit'      => '_parse_exit',
        'say'       => '_parse_builtin_call',
        'print'     => '_parse_builtin_call',
        'ddx'       => '_parse_builtin_call',
        'sleep'     => '_parse_builtin_call',
        'interrupt' => '_parse_builtin_call',
        '{'         => '_parse_block_stmt'
    );

    # Expression Prefix Registry (Starts an expression)
    my %PREFIX_HANDLERS = (
        'NUM'           => '_parse_num_literal',
        'STRING'        => '_parse_string_literal',
        'INTERP_STRING' => '_parse_interpolated_string',
        'VAR'           => '_parse_var_ref',
        'IDENT'         => '_parse_ident_or_call',
        '{'             => '_parse_hash_literal',
        '['             => '_parse_array_literal',
        '('             => '_parse_grouped_expr',
        '!'             => '_parse_unary_op',
        '-'             => '_parse_unary_op',
        'true'          => '_parse_bool_literal',
        'false'         => '_parse_bool_literal',
        'undef'         => '_parse_undef_literal',
        'sub'           => '_parse_anon_sub',
        'fiber'         => '_parse_fiber',
        'yield'         => '_parse_yield',
        'map'           => '_parse_map',
        'sleep'         => '_parse_sleep',
        'exists'        => '_parse_exists',
        'delete'        => '_parse_delete',
        '...'           => '_parse_yada'
    );

    # Expression Infix Registry (Connects two expressions)
    my %INFIX_HANDLERS = (
        '+'   => '_parse_bin_op',
        '-'   => '_parse_bin_op',
        '*'   => '_parse_bin_op',
        '/'   => '_parse_bin_op',
        '%'   => '_parse_bin_op',
        '.'   => '_parse_bin_op',
        '=='  => '_parse_bin_op',
        '!='  => '_parse_bin_op',
        '<'   => '_parse_bin_op',
        '>'   => '_parse_bin_op',
        '<='  => '_parse_bin_op',
        '>='  => '_parse_bin_op',
        'eq'  => '_parse_bin_op',
        'ne'  => '_parse_bin_op',
        'lt'  => '_parse_bin_op',
        'gt'  => '_parse_bin_op',
        'le'  => '_parse_bin_op',
        'ge'  => '_parse_bin_op',
        '&&'  => '_parse_bin_op',
        '||'  => '_parse_bin_op',
        '//'  => '_parse_bin_op',
        '='   => '_parse_bin_op',
        '..'  => '_parse_bin_op',
        '...' => '_parse_bin_op',
        '->'  => '_parse_deref',
        '?'   => '_parse_ternary',
        '['   => '_parse_index_expr',
        '{'   => '_parse_index_expr'
    );

    method _parse_attributes() {
        my @attrs;
        while ( $self->current->{value} eq ':' ) {
            my $col_tok  = $self->advance();         # consume ':'
            my $name_tok = $self->expect('IDENT');
            my $name     = $name_tok->{value};
            my $args     = undef;
            if ( $self->current->{value} eq '(' ) {
                $self->advance();                    # consume '('
                my $arg_tok = $self->current;
                if ( $arg_tok->{type} eq 'IDENT' || $arg_tok->{type} eq 'STRING' || $arg_tok->{type} eq 'VAR' ) {
                    $args = $self->advance()->{value};
                }
                $self->expect(')');
            }
            push @attrs, { name => $name, args => $args, line => $col_tok->{line}, col => $col_tok->{col}, file => $col_tok->{file} };
        }
        return \@attrs;
    }

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

    method _consume_stmt_terminator() {
        if ( $self->current->{value} eq ';' ) {
            $self->advance();
            return 1;
        }
        if ( $self->current->{value} eq '}' || $self->current->{type} eq 'EOF' ) {
            return 1;
        }
        my $tok = $self->current;
        die sprintf "Parse Error L:%d C:%d: Expected ';' or block end, got '%s'\n", $tok->{line}, $tok->{col}, $tok->{value};
    }

    method parse() {
        my @nodes;
        while ( $self->current->{type} ne 'EOF' ) {
            push @nodes, $self->parse_statement();
        }
        return \@nodes;
    }

    method parse_statement() {
        my $val = $self->current->{value};
        if ( $val eq ';' ) {
            $self->advance();
            return undef;
        }
        if ( my $method = $STMT_HANDLERS{$val} ) {
            return $self->$method();
        }
        my $expr = $self->parse_expression(0);
        $self->_consume_stmt_terminator();
        return $expr;
    }

    method parse_expression( $precedence = 0 ) {
        my $tok           = $self->current;
        my $prefix_method = $PREFIX_HANDLERS{ $tok->{value} } // $PREFIX_HANDLERS{ $tok->{type} };
        die "Parse Error L:$tok->{line} C:$tok->{col}: Unexpected token in expression: " . $tok->{value} . "\n" unless $prefix_method;
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

    # Statement Handlers
    method _parse_var_decl() {
        $self->advance();
        my $type = $self->_parse_type_spec();
        my $ntok = $self->expect('VAR');
        $self->expect('=');
        my $val = $self->parse_expression(0);
        $self->_consume_stmt_terminator();
        return Brocken::AST::Stmt::VarDecl->new(
            name  => $ntok->{value},
            type  => $type,
            value => $val,
            line  => $ntok->{line},
            col   => $ntok->{col},
            file  => $ntok->{file}
        );
    }

    method _parse_our_decl() {
        $self->advance();
        my $type = $self->_parse_type_spec();
        my $ntok = $self->expect('VAR');
        my $val  = undef;
        if ( $self->current->{value} eq '=' ) {
            $self->advance();
            $val = $self->parse_expression(0);
        }
        $self->_consume_stmt_terminator();
        return Brocken::AST::Stmt::OurDecl->new(
            name  => $ntok->{value},
            type  => $type,
            value => $val,
            line  => $ntok->{line},
            col   => $ntok->{col},
            file  => $ntok->{file}
        );
    }

    method _parse_state_decl() {
        $self->advance();
        my $type = $self->_parse_type_spec();
        my $ntok = $self->expect('VAR');
        $self->expect('=');
        my $val = $self->parse_expression(0);
        $self->_consume_stmt_terminator();
        return Brocken::AST::Stmt::StateDecl->new(
            name  => $ntok->{value},
            type  => $type,
            value => $val,
            line  => $ntok->{line},
            col   => $ntok->{col},
            file  => $ntok->{file}
        );
    }

    method _parse_if() {
        my $tok = $self->current;
        $self->advance();
        $self->expect('(');
        my $cond = $self->parse_expression(0);
        $self->expect(')');
        my $then = $self->_parse_block_stmt();
        my $else = undef;
        if ( $self->current->{value} eq 'else' ) {
            $self->advance();
            $else = ( $self->current->{value} eq 'if' ) ? $self->_parse_if() : $self->_parse_block_stmt();
        }
        return Brocken::AST::Stmt::If->new(
            condition  => $cond,
            then_block => $then,
            else_block => $else,
            line       => $tok->{line},
            col        => $tok->{col},
            file       => $tok->{file}
        );
    }

    method _parse_unless() {
        my $tok = $self->current;
        $self->advance();
        $self->expect('(');
        my $cond = Brocken::AST::Expr::UnaryOp->new(
            op   => '!',
            expr => $self->parse_expression(0),
            line => $tok->{line},
            col  => $tok->{col},
            file => $tok->{file}
        );
        $self->expect(')');
        return Brocken::AST::Stmt::If->new(
            condition  => $cond,
            then_block => $self->_parse_block_stmt(),
            line       => $tok->{line},
            col        => $tok->{col},
            file       => $tok->{file}
        );
    }

    method _parse_while() {
        my $tok = $self->current;
        $self->advance();
        $self->expect('(');
        my $cond = $self->parse_expression(0);
        $self->expect(')');
        return Brocken::AST::Stmt::While->new(
            condition => $cond,
            body      => $self->_parse_block_stmt(),
            line      => $tok->{line},
            col       => $tok->{col},
            file      => $tok->{file}
        );
    }

    method _parse_until() {
        my $tok = $self->current;
        $self->advance();
        $self->expect('(');
        my $cond = Brocken::AST::Expr::UnaryOp->new(
            op   => '!',
            expr => $self->parse_expression(0),
            line => $tok->{line},
            col  => $tok->{col},
            file => $tok->{file}
        );
        $self->expect(')');
        return Brocken::AST::Stmt::While->new(
            condition => $cond,
            body      => $self->_parse_block_stmt(),
            line      => $tok->{line},
            col       => $tok->{col},
            file      => $tok->{file}
        );
    }

    method _parse_for() {
        my $tok = $self->current;
        $self->advance();    # 'for'
        my $is_my = 0;
        my $var   = '$_';    # default
        if ( $self->current->{value} eq 'my' ) {
            $is_my = 1;
            $self->advance();
            if ( $self->current->{value} eq '(' ) {
                $self->advance();
                $var = [];
                while ( $self->current->{value} ne ')' ) {
                    push @$var, $self->expect('VAR')->{value};
                    if ( $self->current->{value} eq ',' ) { $self->advance(); }
                }
                $self->expect(')');
            }
            else {
                $var = $self->expect('VAR')->{value};
            }
        }
        elsif ( $self->current->{type} eq 'VAR' ) {
            $var = $self->current->{value};
            $self->advance();
        }
        my $source;
        if ( $self->current->{value} eq '(' ) {
            $self->advance();
            $source = $self->parse_expression(0);
            $self->expect(')');
        }
        else {
            $source = $self->parse_expression(0);
        }
        my $body = $self->_parse_block_stmt();
        return Brocken::AST::Stmt::For->new(
            var    => $var,
            source => $source,
            body   => $body,
            is_my  => $is_my,
            line   => $tok->{line},
            col    => $tok->{col},
            file   => $tok->{file}
        );
    }

    method _parse_next_last_redo() {
        my $tok  = $self->current;
        my $type = $self->advance()->{value};
        $self->_consume_stmt_terminator();
        my $class = "Brocken::AST::Stmt::" . ucfirst($type);
        return $class->new( line => $tok->{line}, col => $tok->{col}, file => $tok->{file} );
    }

    method _parse_return() {
        my $tok = $self->current;
        $self->advance();
        my $expr = ( $self->current->{value} ne ';' ) ? $self->parse_expression(0) : undef;
        $self->_consume_stmt_terminator();
        return Brocken::AST::Stmt::Return->new( expr => $expr, line => $tok->{line}, col => $tok->{col}, file => $tok->{file} );
    }

    method _parse_exit() {
        my $tok = $self->current;
        $self->advance();
        my $expr = $self->current->{value} ne ';' ? $self->parse_expression(0) : undef;
        $self->_consume_stmt_terminator();
        return Brocken::AST::Stmt::Exit->new( expr => $expr, line => $tok->{line}, col => $tok->{col}, file => $tok->{file} );
    }

    method _parse_builtin_call() {
        my $tok  = $self->advance();
        my $name = $tok->{value};
        my @args;
        if ( $self->current->{value} ne ';' && $self->current->{value} ne '}' && $self->current->{type} ne 'EOF' ) {
            while (1) {
                push @args, $self->parse_expression(0);
                if ( $self->current->{value} eq ',' ) {
                    $self->advance();
                    next;
                }
                last;
            }
        }
        $self->_consume_stmt_terminator();
        return Brocken::AST::Expr::Call->new( name => $name, args => \@args, line => $tok->{line}, col => $tok->{col}, file => $tok->{file} );
    }

    method _parse_sub_stmt() {
        my $tok = $self->current;
        $self->advance();
        my $name   = $self->expect('IDENT')->{value};
        my $params = $self->_parse_routine_params();
        my $body   = $self->_parse_block_stmt();
        return Brocken::AST::OOP::Method->new(
            name   => $name,
            params => $params,
            body   => $body,
            line   => $tok->{line},
            col    => $tok->{col},
            file   => $tok->{file}
        );
    }

    method _parse_defer() {
        my $tok = $self->current;
        $self->advance();
        my $block = $self->_parse_block_stmt();
        return Brocken::AST::Stmt::Defer->new( block => $block, line => $tok->{line}, col => $tok->{col}, file => $tok->{file} );
    }

    method _parse_use() {
        my $tok = $self->current;
        $self->advance();
        my $package = $self->expect('IDENT')->{value};
        while ( $self->current->{value} eq '::' ) {
            $self->advance();
            $package .= '::' . $self->expect('IDENT')->{value};
        }
        $self->expect(';');
        return Brocken::AST::Stmt::Use->new( package => $package, line => $tok->{line}, col => $tok->{col}, file => $tok->{file} );
    }

    method _parse_require() {
        my $tok = $self->current;
        $self->advance();
        my $package = $self->expect('IDENT')->{value};
        while ( $self->current->{value} eq '::' ) {
            $self->advance();
            $package .= '::' . $self->expect('IDENT')->{value};
        }
        $self->expect(';');
        return Brocken::AST::Stmt::Require->new( package => $package, line => $tok->{line}, col => $tok->{col}, file => $tok->{file} );
    }

    method _parse_native_decl() {
        my $tok     = $self->advance();
        my $library = $self->expect('STRING')->{value};
        $self->expect(',');
        my $name = $self->expect('STRING')->{value};
        $self->expect(',');
        my $signature = $self->expect('STRING')->{value};
        $self->_consume_stmt_terminator();
        return Brocken::AST::NativeDecl->new(
            library   => $library,
            name      => $name,
            signature => $signature,
            line      => $tok->{line},
            col       => $tok->{col},
            file      => $tok->{file}
        );
    }

    method _parse_eval() {
        my $tok = $self->current;
        $self->advance();
        my $code_expr = $self->parse_expression(0);
        $self->expect(';');
        return Brocken::AST::Stmt::Eval->new( code => $code_expr, line => $tok->{line}, col => $tok->{col}, file => $tok->{file} );
    }

    method _parse_die() {
        my $tok = $self->current;
        $self->advance;
        my $code_expr = $self->current->{value} ne ';' ? $self->parse_expression(0) : undef;
        $self->_consume_stmt_terminator();
        return Brocken::AST::Exception::Die->new( exception => $code_expr, line => $tok->{line}, col => $tok->{col}, file => $tok->{file} );
    }

    method _parse_try_catch() {
        my $tok = $self->current;
        $self->advance();
        my $try = $self->_parse_block_stmt();
        $self->expect('catch');
        $self->expect('(');
        my $catch_arg = $self->expect('VAR');
        $self->expect(')');
        my $catch   = $self->_parse_block_stmt();
        my $finally = undef;

        if ( $self->current->{type} eq 'KEYWORD' && $self->current->{value} eq 'finally' ) {
            $self->advance();
            $finally = $self->_parse_block_stmt();
        }
        return Brocken::AST::Exception::TryCatch->new(
            try_block     => $try,
            catch_var     => $catch_arg,
            catch_block   => $catch,
            finally_block => $finally,
            line          => $tok->{line},
            col           => $tok->{col},
            file          => $tok->{file}
        );
    }

    method _parse_class() {
        my $tok = $self->current;
        $self->advance();
        my $name = $self->expect('IDENT')->{value};
        while ( $self->current->{value} eq '::' ) {
            $self->advance();
            $name .= '::' . $self->expect('IDENT')->{value};
        }
        my $attrs = $self->_parse_attributes();
        $self->expect('{');
        my ( @fields, @methods );
        while ( $self->current->{value} ne '}' ) {
            my $v = $self->current->{value};
            if ( $v eq 'field' ) {
                $self->advance();
                my $type   = $self->_parse_type_spec();
                my $ftok   = $self->expect('VAR');
                my $fattrs = $self->_parse_attributes();
                $self->expect(';');
                push @fields,
                    Brocken::AST::OOP::FieldDecl->new(
                    name       => $ftok->{value},
                    type       => $type,
                    attributes => $fattrs,
                    line       => $ftok->{line},
                    col        => $ftok->{col},
                    file       => $ftok->{file}
                    );
            }
            elsif ( $v eq 'method' ) {
                my $mtok = $self->current;
                $self->advance();
                my $mname  = $self->expect('IDENT')->{value};
                my $params = $self->_parse_routine_params();
                my $mattrs = $self->_parse_attributes();
                push @methods,
                    Brocken::AST::OOP::Method->new(
                    name       => $mname,
                    params     => $params,
                    attributes => $mattrs,
                    body       => $self->_parse_block_stmt(),
                    line       => $mtok->{line},
                    col        => $mtok->{col},
                    file       => $mtok->{file}
                    );
            }
            else { die "Unexpected token in class $name: " . $self->current->{value}; }
        }
        $self->expect('}');
        return Brocken::AST::OOP::ClassDecl->new(
            name       => $name,
            fields     => \@fields,
            methods    => \@methods,
            attributes => $attrs,
            line       => $tok->{line},
            col        => $tok->{col},
            file       => $tok->{file}
        );
    }

    method _parse_block_stmt() {
        my $tok = $self->current;
        $self->expect('{');
        my @stmts;
        while ( $self->current->{value} ne '}' ) {
            my $node = $self->parse_statement();
            push @stmts, $node if defined $node;
        }
        $self->expect('}');
        return Brocken::AST::Stmt::Block->new( statements => \@stmts, line => $tok->{line}, col => $tok->{col}, file => $tok->{file} );
    }

    # --- Expression Prefix Handlers ---
    method _parse_exists($tok) {
        $self->advance();
        return Brocken::AST::Expr::Exists->new( expr => $self->parse_expression(0), line => $tok->{line}, col => $tok->{col}, file => $tok->{file} );
    }

    method _parse_delete($tok) {
        $self->advance();
        return Brocken::AST::Expr::Delete->new( expr => $self->parse_expression(0), line => $tok->{line}, col => $tok->{col}, file => $tok->{file} );
    }

    method _parse_yada($tok) {
        $self->advance();
        return Brocken::AST::Stmt::Yada->new( line => $tok->{line}, col => $tok->{col}, file => $tok->{file} );
    }

    method _parse_num_literal($tok) {
        $self->advance();
        Brocken::AST::Expr::Const->new( value => $tok->{value}, type => 'Int', line => $tok->{line}, col => $tok->{col}, file => $tok->{file} );
    }

    method _parse_string_literal($tok) {
        $self->advance();
        Brocken::AST::Expr::Const->new( value => $tok->{value}, type => 'String', line => $tok->{line}, col => $tok->{col}, file => $tok->{file} );
    }

    method _parse_interpolated_string($tok) {
        $self->advance();
        my $parts = $tok->{value};
        my $expr;
        for my $part (@$parts) {
            my $node;
            if ( $part->[0] eq 'STRING' ) {
                $node = Brocken::AST::Expr::Const->new(
                    value => $part->[1],
                    type  => 'String',
                    line  => $tok->{line},
                    col   => $tok->{col},
                    file  => $tok->{file}
                );
            }
            else {
                $node = Brocken::AST::Expr::Var->new( name => $part->[1], line => $tok->{line}, col => $tok->{col}, file => $tok->{file} );
            }
            if ( defined $expr ) {
                $expr = Brocken::AST::Expr::BinOp->new(
                    op    => '.',
                    left  => $expr,
                    right => $node,
                    line  => $tok->{line},
                    col   => $tok->{col},
                    file  => $tok->{file}
                );
            }
            else {
                $expr = $node;
            }
        }
        return $expr
            // Brocken::AST::Expr::Const->new( value => '', type => 'String', line => $tok->{line}, col => $tok->{col}, file => $tok->{file} );
    }

    method _parse_bool_literal($tok) {
        $self->advance();
        Brocken::AST::Expr::Const->new(
            value => ( $tok->{value} eq 'true' ? 1 : 0 ),
            type  => 'Int',
            line  => $tok->{line},
            col   => $tok->{col},
            file  => $tok->{file}
        );
    }

    method _parse_undef_literal($tok) {
        $self->advance();
        return Brocken::AST::Expr::Const->new( value => 'undef', type => 'Undef', line => $tok->{line}, col => $tok->{col}, file => $tok->{file} );
    }

    method _parse_var_ref($tok) {
        $self->advance();
        Brocken::AST::Expr::Var->new( name => $tok->{value}, line => $tok->{line}, col => $tok->{col}, file => $tok->{file} );
    }

    method _parse_ident_or_call($tok) {
        my $name = $tok->{value};
        $self->advance();
        while ( $self->current->{value} eq '::' ) {
            $self->advance();
            $name .= '::' . $self->expect('IDENT')->{value};
        }
        if ( $self->current->{value} eq '(' ) {
            return Brocken::AST::Expr::Call->new(
                name => $name,
                args => $self->_parse_args(),
                line => $tok->{line},
                col  => $tok->{col},
                file => $tok->{file}
            );
        }
        if ( $self->current->{value} eq '->' ) {
            $self->advance();
            my $method_name = $self->expect('IDENT')->{value};
            my $args        = $self->current->{value} eq '(' ? $self->_parse_args() : [];
            my $class_const
                = Brocken::AST::Expr::Const->new( value => $name, type => 'Class', line => $tok->{line}, col => $tok->{col}, file => $tok->{file} );
            return Brocken::AST::Expr::MethodCall->new(
                object => $class_const,
                method => $method_name,
                args   => $args,
                line   => $tok->{line},
                col    => $tok->{col},
                file   => $tok->{file}
            );
        }

        # --- UPDATE: Map bareword standard I/O handles directly to Var nodes ---
        if ( $name =~ /^(STDOUT|STDERR|STDIN)$/ ) {
            return Brocken::AST::Expr::Var->new( name => $name, line => $tok->{line}, col => $tok->{col}, file => $tok->{file} );
        }
        return Brocken::AST::Expr::Const->new( value => $name, type => 'Class', line => $tok->{line}, col => $tok->{col}, file => $tok->{file} );
    }

    method _parse_grouped_expr($tok) {
        $self->advance();
        if ( $self->current->{value} eq ')' ) {
            $self->advance();
            return Brocken::AST::Expr::TupleLiteral->new( elements => [], line => $tok->{line}, col => $tok->{col}, file => $tok->{file} );
        }
        my $expr = $self->parse_expression(0);
        if ( $self->current->{value} eq ',' ) {
            my @elements = ($expr);
            while ( $self->current->{value} eq ',' ) {
                $self->advance();
                last if $self->current->{value} eq ')';
                push @elements, $self->parse_expression(0);
            }
            $self->expect(')');
            return Brocken::AST::Expr::TupleLiteral->new( elements => \@elements, line => $tok->{line}, col => $tok->{col}, file => $tok->{file} );
        }
        $self->expect(')');
        return $expr;
    }

    method _parse_unary_op($tok) {
        $self->advance();
        return Brocken::AST::Expr::UnaryOp->new(
            op   => $tok->{value},
            expr => $self->parse_expression(40),
            line => $tok->{line},
            col  => $tok->{col},
            file => $tok->{file}
        );
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
        return Brocken::AST::Expr::ArrayLiteral->new( elements => \@el, line => $tok->{line}, col => $tok->{col}, file => $tok->{file} );
    }

    method _parse_anon_sub($tok) {
        $self->advance();
        my $params = $self->_parse_routine_params();
        my $body   = $self->_parse_block_stmt();
        return Brocken::AST::OOP::AnonSub->new( params => $params, body => $body, line => $tok->{line}, col => $tok->{col}, file => $tok->{file} );
    }

    method _parse_fiber($tok) {
        $self->advance();
        my $params = ( $self->current->{value} eq '(' ) ? $self->_parse_routine_params() : [];
        return Brocken::AST::Async::FiberBlock->new(
            params => $params,
            body   => $self->_parse_block_stmt(),
            line   => $tok->{line},
            col    => $tok->{col},
            file   => $tok->{file}
        );
    }

    method _parse_yield($tok) {
        $self->advance();
        my $expr = $self->current->{value} ne ';' ? $self->parse_expression(0) : undef;
        return Brocken::AST::Async::Yield->new( expr => $expr, line => $tok->{line}, col => $tok->{col}, file => $tok->{file} );
    }

    method _parse_sleep($tok) {
        $self->advance();
        my $expr = $self->parse_expression(0);
        return Brocken::AST::Async::Sleep->new( expr => $expr, line => $tok->{line}, col => $tok->{col}, file => $tok->{file} );
    }

    method _parse_map($tok) {
        $self->advance();
        $self->expect('{');
        my $expr = $self->parse_expression(0);
        $self->expect('}');
        return Brocken::AST::Stmt::Map->new(
            expr   => $expr,
            source => $self->parse_expression(25),
            line   => $tok->{line},
            col    => $tok->{col},
            file   => $tok->{file}
        );
    }

    # --- Expression Infix Handlers ---
    method _parse_bin_op( $left, $op ) {
        my $p = $PRECEDENCE{$op};
        $p-- if $op eq '=';
        my $right = $self->parse_expression($p);
        if ( $op eq '=' ) {
            if ( $left isa Brocken::AST::Expr::Var ) {
                return Brocken::AST::Stmt::Assignment->new(
                    name  => $left->name,
                    value => $right,
                    line  => $left->line,
                    col   => $left->col,
                    file  => $left->file
                );
            }
            if ( $left isa Brocken::AST::Expr::IndexExpr ) {
                return Brocken::AST::Stmt::Assignment->new(
                    name  => $left,
                    value => $right,
                    line  => $left->line,
                    col   => $left->col,
                    file  => $left->file
                );
            }
            if ( $left isa Brocken::AST::Expr::MethodCall ) {
                return Brocken::AST::Stmt::Assignment->new(
                    name  => $left,
                    value => $right,
                    line  => $left->line,
                    col   => $left->col,
                    file  => $left->file
                );
            }
            die "Parse Error L:" . $left->line . " C:" . $left->col . ": Left side of assignment must be a variable, index, or field expression";
        }
        return Brocken::AST::Expr::BinOp->new( op => $op, left => $left, right => $right, line => $left->line, col => $left->col,
            file => $left->file );
    }

    method _parse_ternary( $left, $op ) {
        my $then = $self->parse_expression(0);
        $self->expect(':');
        my $else = $self->parse_expression(0);
        return Brocken::AST::Expr::Ternary->new(
            cond => $left,
            then => $then,
            else => $else,
            line => $left->line,
            col  => $left->col,
            file => $left->file
        );
    }

    method _parse_index_expr( $left, $op ) {
        my $index;
        if ( $op eq '{' && $self->current->{type} eq 'IDENT' && $self->peek->{value} eq '}' ) {
            my $ident_tok = $self->current;
            $self->advance();
            $index = Brocken::AST::Expr::Const->new(
                value => $ident_tok->{value},
                type  => 'String',
                line  => $ident_tok->{line},
                col   => $ident_tok->{col},
                file  => $ident_tok->{file}
            );
        }
        else {
            $index = $self->parse_expression(0);
        }
        $self->expect( $op eq '{' ? '}' : ']' );
        return Brocken::AST::Expr::IndexExpr->new( source => $left, index => $index, line => $left->line, col => $left->col, file => $left->file );
    }

    method _parse_hash_literal($tok) {
        $self->advance();
        my @pairs;
        while ( $self->current->{value} ne '}' ) {
            my $key;
            if ( $self->current->{type} eq 'IDENT' && $self->peek->{value} eq '=>' ) {
                my $ident_tok = $self->current;
                $self->advance();
                $key = Brocken::AST::Expr::Const->new(
                    value => $ident_tok->{value},
                    type  => 'String',
                    line  => $ident_tok->{line},
                    col   => $ident_tok->{col},
                    file  => $ident_tok->{file}
                );
            }
            else {
                $key = $self->parse_expression(0);
            }
            $self->expect('=>');
            my $val = $self->parse_expression(0);
            push @pairs, { key => $key, value => $val };
            last if $self->current->{value} eq '}';
            $self->expect(',');
        }
        $self->expect('}');
        return Brocken::AST::Expr::HashLiteral->new( pairs => \@pairs, line => $tok->{line}, col => $tok->{col}, file => $tok->{file} );
    }

    method _parse_deref( $left, $op ) {
        if ( $self->current->{value} eq '(' ) {
            return Brocken::AST::Expr::AnonCall->new(
                invocant => $left,
                args     => $self->_parse_args(),
                line     => $left->line,
                col      => $left->col,
                file     => $left->file
            );
        }
        my $mname = $self->expect('IDENT')->{value};
        return Brocken::AST::Expr::MethodCall->new(
            object => $left,
            method => $mname,
            args   => $self->current->{value} eq '(' ? $self->_parse_args() : [],
            line   => $left->line,
            col    => $left->col,
            file   => $left->file
        );
    }

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
        if ( $self->current->{type} eq 'KEYWORD' && $self->current->{value} =~ /^[A-Za-z_][A-Za-z0-9_]*$/ ) {
            my $t = $self->current->{value};
            $self->advance();
            if ( $t eq 'Callback' && $self->current->{type} eq 'OP' && $self->current->{value} eq '[' ) {
                $self->advance();
                my @arg_types;
                if ( $self->current->{value} eq '[' ) {
                    $self->advance();
                    while ( $self->current->{value} ne ']' ) {
                        push @arg_types, $self->_parse_type_spec();
                        if ( $self->current->{value} eq ']' ) { last; }
                        $self->expect(',');
                    }
                    $self->expect(']');
                    $self->expect('=>');
                    my $ret_type = $self->_parse_type_spec();
                    $self->expect(']');
                    my $args_str = join( ',', @arg_types );
                    return "Callback[$args_str=>$ret_type]";
                }
                else {
                    while ( $self->current->{value} ne ']' ) {
                        push @arg_types, $self->_parse_type_spec();
                        last if $self->current->{value} eq ']';
                        $self->expect(',');
                    }
                    $self->expect(']');
                    $self->expect('=>');
                    my $ret_type = $self->_parse_type_spec();
                    my $args_str = join( ',', @arg_types );
                    return "Callback[$args_str=>$ret_type]";
                }
            }
            return $t;
        }
        return 'Any';
    }
}
1;
__END__

=pod

=head1 NAME

Brocken::Parser - Pratt parser for Brocken

=head1 SYNOPSIS

    my $parser = Brocken::Parser->new( tokens => $tokens );
    my $ast = $parser->parse();

=head1 DESCRIPTION

Top-down operator precedence (Pratt) parser. Uses three registries:

=over

=item C<%STMT_HANDLERS>

Maps keyword strings to parsing methods for statements (C<if>, C<while>, C<class>, C<sub>, C<return>, C<defer>, etc.).

=item C<%PREFIX_HANDLERS>

Handles tokens that start expressions: literals, variables, identifiers, unary ops, grouping, and expression-level
keywords (C<sub>, C<fiber>, C<yield>, C<map>).

=item C<%INFIX_HANDLERS>

Handles binary operators between expressions: arithmetic, comparison, logical, assignment, dereference, ternary.

=back

Returns an arrayref of AST nodes from C<parse()>.

=head1 METHODS

=head2 parse

  my $ast = Brocken::Parser->new( tokens => $tokens )->parse();

Returns an arrayref of AST::Node objects.

=head2 parse_expression($precedence)

Parse an expression starting at the current token position.

=cut
