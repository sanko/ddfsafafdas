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
        '||' => 12, '//' => 12,                                                  #
        '&&' => 13,                                                              #
        '==' => 15, '!=' => 15, '<' => 15, '>' => 15, '<=' => 15, '>=' => 15,    #
        '+'  => 20, '-'  => 20, '.' => 20,                                       #
        '*'  => 30, '/'  => 30, '%' => 30,                                       #
        '['  => 50,                                                              #
        '->' => 60,                                                              #
        '('  => 70,                                                              # Expression calls
    );

    # Statement Registry (Keyword -> Method)
    my %STMT_HANDLERS = (
        'my'        => '_parse_var_decl',
        'state'     => '_parse_state_decl',
        'if'        => '_parse_if',
        'unless'    => '_parse_unless',
        'while'     => '_parse_while',
        'until'     => '_parse_until',
        'class'     => '_parse_class',
        'sub'       => '_parse_sub_stmt',
        'defer'     => '_parse_defer',
        'return'    => '_parse_return',
        'exit'      => '_parse_exit',
        'say'       => '_parse_builtin_call',
        'print'     => '_parse_builtin_call',
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
        '['             => '_parse_array_literal',
        '('             => '_parse_grouped_expr',
        '!'             => '_parse_unary_op',
        'true'          => '_parse_bool_literal',
        'false'         => '_parse_bool_literal',
        'undef'         => '_parse_undef_literal',
        'sub'           => '_parse_anon_sub',
        'fiber'         => '_parse_fiber',
        'yield'         => '_parse_yield',
        'map'           => '_parse_map',
        'sleep'         => '_parse_sleep',
    );

    # Expression Infix Registry (Connects two expressions)
    my %INFIX_HANDLERS = (
        '+'  => '_parse_bin_op',
        '-'  => '_parse_bin_op',
        '*'  => '_parse_bin_op',
        '/'  => '_parse_bin_op',
        '%'  => '_parse_bin_op',
        '.'  => '_parse_bin_op',
        '==' => '_parse_bin_op',
        '!=' => '_parse_bin_op',
        '<'  => '_parse_bin_op',
        '>'  => '_parse_bin_op',
        '<=' => '_parse_bin_op',
        '>=' => '_parse_bin_op',
        '&&' => '_parse_bin_op',
        '||' => '_parse_bin_op',
        '//' => '_parse_bin_op',
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

    # Utils
    method _consume_stmt_terminator() {
        if ( $self->current->{value} eq ';' ) {
            $self->advance();
            return 1;
        }

        # If the next token is a closing brace or end of file,
        # we allow the semicolon to be omitted (Perl behavior).
        if ( $self->current->{value} eq '}' || $self->current->{type} eq 'EOF' ) {
            return 1;
        }

        # Otherwise, it's a legitimate missing semicolon error
        my $tok = $self->current;
        die sprintf "Parse Error L:%d C:%d: Expected ';' or block end, got '%s'\n", $tok->{line}, $tok->{col}, $tok->{value};
    }
    #
    method parse() {
        my @nodes;
        while ( $self->current->{type} ne 'EOF' ) {
            push @nodes, $self->parse_statement();
        }
        return \@nodes;
    }

    method parse_statement() {
        my $val = $self->current->{value};

        # Handle bare semicolons (empty statements: ;;;;)
        if ( $val eq ';' ) {
            $self->advance();
            return undef;    # Lowering handles undef nodes gracefully
        }
        if ( my $method = $STMT_HANDLERS{$val} ) {
            return $self->$method();
        }

        # Fallback: Handle expressions as statements (e.g., $x = 10)
        my $expr = $self->parse_expression(0);
        $self->_consume_stmt_terminator();    # Use the new helper here
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
        $self->advance();    # consume 'my'
        my $type = $self->_parse_type_spec();
        my $ntok = $self->expect('VAR');
        $self->expect('=');
        my $val = $self->parse_expression(0);
        $self->_consume_stmt_terminator();
        return Brocken::AST::Stmt::VarDecl->new( name => $ntok->{value}, type => $type, value => $val, line => $ntok->{line}, col => $ntok->{col} );
    }

    method _parse_state_decl() {
        $self->advance();    # consume 'state'
        my $type = $self->_parse_type_spec();
        my $ntok = $self->expect('VAR');
        $self->expect('=');
        my $val = $self->parse_expression(0);
        $self->_consume_stmt_terminator();
        return Brocken::AST::Stmt::StateDecl->new( name => $ntok->{value}, type => $type, value => $val, line => $ntok->{line}, col => $ntok->{col} );
    }

    method _parse_if() {
        my $tok = $self->current;
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
        return Brocken::AST::Stmt::If->new( condition => $cond, then_block => $then, else_block => $else, line => $tok->{line}, col => $tok->{col} );
    }

    method _parse_unless() {
        my $tok = $self->current;
        $self->advance();
        $self->expect('(');
        my $cond = Brocken::AST::Expr::UnaryOp->new( op => '!', expr => $self->parse_expression(0), line => $tok->{line}, col => $tok->{col} );
        $self->expect(')');
        return Brocken::AST::Stmt::If->new( condition => $cond, then_block => $self->_parse_block_stmt(), line => $tok->{line}, col => $tok->{col} );
    }

    method _parse_while() {
        my $tok = $self->current;
        $self->advance();
        $self->expect('(');
        my $cond = $self->parse_expression(0);
        $self->expect(')');
        return Brocken::AST::Stmt::While->new( condition => $cond, body => $self->_parse_block_stmt(), line => $tok->{line}, col => $tok->{col} );
    }

    method _parse_until() {
        my $tok = $self->current;
        $self->advance();
        $self->expect('(');
        my $cond = Brocken::AST::Expr::UnaryOp->new( op => '!', expr => $self->parse_expression(0), line => $tok->{line}, col => $tok->{col} );
        $self->expect(')');
        return Brocken::AST::Stmt::While->new( condition => $cond, body => $self->_parse_block_stmt(), line => $tok->{line}, col => $tok->{col} );
    }

    method _parse_return() {
        my $tok = $self->current;
        $self->advance();
        my $expr = ( $self->current->{value} ne ';' ) ? $self->parse_expression(0) : undef;
        $self->_consume_stmt_terminator();
        return Brocken::AST::Stmt::Return->new( expr => $expr, line => $tok->{line}, col => $tok->{col} );
    }

    method _parse_exit() {
        my $tok = $self->current;
        $self->advance();
        my $expr = $self->current->{value} ne ';' ? $self->parse_expression(0) : undef;
        $self->_consume_stmt_terminator();
        return Brocken::AST::Stmt::Exit->new( expr => $expr, line => $tok->{line}, col => $tok->{col} );
    }

    method _parse_builtin_call() {
        my $tok  = $self->advance();    # consume the keyword (print, say, open, etc)
        my $name = $tok->{value};
        my @args;

        # Only try to parse arguments if the next token isn't a statement terminator
        if ( $self->current->{value} ne ';' && $self->current->{value} ne '}' && $self->current->{type} ne 'EOF' ) {
            while (1) {
                push @args, $self->parse_expression(0);

                # If we see a comma, consume it and continue to the next argument
                if ( $self->current->{value} eq ',' ) {
                    $self->advance();
                    next;
                }

                # No comma? We are done with the argument list
                last;
            }
        }
        $self->_consume_stmt_terminator();
        return Brocken::AST::Expr::Call->new( name => $name, args => \@args, line => $tok->{line}, col => $tok->{col} );
    }

    method _parse_sub_stmt() {
        my $tok = $self->current;
        $self->advance();    # consume 'sub'
        my $name   = $self->expect('IDENT')->{value};
        my $params = $self->_parse_routine_params();
        my $body   = $self->_parse_block_stmt();
        return Brocken::AST::OOP::Method->new( name => $name, params => $params, body => $body, line => $tok->{line}, col => $tok->{col} );
    }

    method _parse_defer() {
        my $tok = $self->current;
        $self->advance();    # consume 'defer'
        my $block = $self->_parse_block_stmt();
        return Brocken::AST::Stmt::Defer->new( block => $block, line => $tok->{line}, col => $tok->{col} );
    }

    method _parse_class() {
        my $tok = $self->current;
        $self->advance();    # consume 'class'
        my $name = $self->expect('IDENT')->{value};
        $self->expect('{');
        my ( @fields, @methods );
        while ( $self->current->{value} ne '}' ) {
            my $v = $self->current->{value};
            if ( $v eq 'field' ) {
                $self->advance();
                my $type = $self->_parse_type_spec();
                my $ftok = $self->expect('VAR');
                $self->expect(';');
                push @fields, Brocken::AST::OOP::FieldDecl->new( name => $ftok->{value}, type => $type, line => $ftok->{line}, col => $ftok->{col} );
            }
            elsif ( $v eq 'method' ) {
                my $mtok = $self->current;
                $self->advance();
                my $mname  = $self->expect('IDENT')->{value};
                my $params = $self->_parse_routine_params();
                push @methods,
                    Brocken::AST::OOP::Method->new(
                    name   => $mname,
                    params => $params,
                    body   => $self->_parse_block_stmt(),
                    line   => $mtok->{line},
                    col    => $mtok->{col}
                    );
            }
            else { die "Unexpected token in class $name: " . $self->current->{value}; }
        }
        $self->expect('}');
        return Brocken::AST::OOP::ClassDecl->new( name => $name, fields => \@fields, methods => \@methods, line => $tok->{line}, col => $tok->{col} );
    }

    method _parse_block_stmt() {
        my $tok = $self->current;
        $self->expect('{');
        my @stmts;
        while ( $self->current->{value} ne '}' ) {
            my $node = $self->parse_statement();
            push @stmts, $node if defined $node;    # Don't collect empty statements
        }
        $self->expect('}');
        return Brocken::AST::Stmt::Block->new( statements => \@stmts, line => $tok->{line}, col => $tok->{col} );
    }

    # --- Expression Prefix Handlers ---
    method _parse_num_literal($tok) {
        $self->advance();
        Brocken::AST::Expr::Const->new( value => $tok->{value}, type => 'Int', line => $tok->{line}, col => $tok->{col} );
    }

    method _parse_string_literal($tok) {
        $self->advance();
        Brocken::AST::Expr::Const->new( value => $tok->{value}, type => 'String', line => $tok->{line}, col => $tok->{col} );
    }

    method _parse_interpolated_string($tok) {
        $self->advance();
        my $parts = $tok->{value};
        my $expr;
        for my $part (@$parts) {
            my $node;
            if ( $part->[0] eq 'STRING' ) {
                $node = Brocken::AST::Expr::Const->new( value => $part->[1], type => 'String', line => $tok->{line}, col => $tok->{col} );
            }
            else {
                $node = Brocken::AST::Expr::Var->new( name => $part->[1], line => $tok->{line}, col => $tok->{col} );
            }
            if ( defined $expr ) {
                $expr = Brocken::AST::Expr::BinOp->new( op => '.', left => $expr, right => $node, line => $tok->{line}, col => $tok->{col} );
            }
            else {
                $expr = $node;
            }
        }
        return $expr // Brocken::AST::Expr::Const->new( value => '', type => 'String', line => $tok->{line}, col => $tok->{col} );
    }

    method _parse_bool_literal($tok) {
        $self->advance();
        Brocken::AST::Expr::Const->new( value => ( $tok->{value} eq 'true' ? 1 : 0 ), type => 'Int', line => $tok->{line}, col => $tok->{col} );
    }

    method _parse_undef_literal($tok) {
        $self->advance();
        Brocken::AST::Expr::Const->new( value => 0, type => 'Any', line => $tok->{line}, col => $tok->{col} );
    }
    method _parse_var_ref($tok) { $self->advance(); Brocken::AST::Expr::Var->new( name => $tok->{value}, line => $tok->{line}, col => $tok->{col} ) }

    method _parse_ident_or_call($tok) {
        my $name = $tok->{value};
        $self->advance();
        if ( $self->current->{value} eq '(' ) {
            return Brocken::AST::Expr::Call->new( name => $name, args => $self->_parse_args(), line => $tok->{line}, col => $tok->{col} );
        }

        # Treat bare Ident as a Class reference for now
        return Brocken::AST::Expr::Const->new( value => $name, type => 'Class', line => $tok->{line}, col => $tok->{col} );
    }

    method _parse_grouped_expr($tok) {
        $self->advance();
        my $expr = $self->parse_expression(0);
        $self->expect(')');
        return $expr;
    }

    method _parse_unary_op($tok) {
        $self->advance();
        return Brocken::AST::Expr::UnaryOp->new( op => $tok->{value}, expr => $self->parse_expression(40), line => $tok->{line}, col => $tok->{col} );
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
        return Brocken::AST::Expr::ArrayLiteral->new( elements => \@el, line => $tok->{line}, col => $tok->{col} );
    }

    method _parse_anon_sub($tok) {
        $self->advance();
        my $params = $self->_parse_routine_params();
        my $body   = $self->_parse_block_stmt();
        return Brocken::AST::OOP::AnonSub->new( params => $params, body => $body, line => $tok->{line}, col => $tok->{col} );
    }

    method _parse_fiber($tok) {
        $self->advance();
        my $params = ( $self->current->{value} eq '(' ) ? $self->_parse_routine_params() : [];
        return Brocken::AST::Async::FiberBlock->new( params => $params, body => $self->_parse_block_stmt(), line => $tok->{line},
            col => $tok->{col} );
    }

    method _parse_yield($tok) {
        $self->advance();
        my $expr = $self->current->{value} ne ';' ? $self->parse_expression(0) : undef;
        return Brocken::AST::Async::Yield->new( expr => $expr, line => $tok->{line}, col => $tok->{col} );
    }

    method _parse_sleep($tok) {
        $self->advance();
        my $expr = $self->parse_expression(0);
        return Brocken::AST::Async::Sleep->new( expr => $expr, line => $tok->{line}, col => $tok->{col} );
    }

    method _parse_map($tok) {
        $self->advance();
        $self->expect('{');
        my $expr = $self->parse_expression(0);
        $self->expect('}');

        # map consumes source with relatively low precedence
        return Brocken::AST::Stmt::Map->new( expr => $expr, source => $self->parse_expression(25), line => $tok->{line}, col => $tok->{col} );
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
                return Brocken::AST::Stmt::Assignment->new( name => $left->name, value => $right, line => $left->line, col => $left->col );
            }

            # For Milestone 3/4: Support $obj->field = val
            # if ($left isa Brocken::AST::OOP::MethodCall) { ... }
            warn ref $left;
            die "Parse Error: Left side of assignment must be a variable";
        }
        return Brocken::AST::Expr::BinOp->new( op => $op, left => $left, right => $right, line => $left->line, col => $left->col );
    }

    method _parse_ternary( $left, $op ) {
        my $then = $self->parse_expression(0);
        $self->expect(':');
        my $else = $self->parse_expression(0);
        return Brocken::AST::Expr::Ternary->new( cond => $left, then => $then, else => $else, line => $left->line, col => $left->col );
    }

    method _parse_deref( $left, $op ) {
        if ( $self->current->{value} eq '(' ) {
            return Brocken::AST::Expr::AnonCall->new( invocant => $left, args => $self->_parse_args(), line => $left->line, col => $left->col );
        }
        my $mname = $self->expect('IDENT')->{value};
        return Brocken::AST::OOP::MethodCall->new(
            invocant => $left,
            name     => $mname,
            args     => $self->_parse_args(),
            line     => $left->line,
            col      => $left->col
        );
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
        if ( $self->current->{type} eq 'KEYWORD' && $self->current->{value} =~ /^(?:Int|String|Any|Bool|Class|Fiber|Array)$/ ) {
            my $t = $self->current->{value};
            $self->advance();
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
1;
