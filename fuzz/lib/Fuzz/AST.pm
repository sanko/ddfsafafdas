package Fuzz::AST;
use v5.40;
use strict;
use warnings;
use Exporter 'import';
our @EXPORT_OK = qw(
    random_ast random_expr random_stmt random_block
    random_var_decl random_assignment random_if random_while
    random_return random_sub random_class random_fiber
    random_program ast_size count_nodes ast_equals
);
use Brocken::AST;

# --- RNG ---
my $rng_seed = 42;
sub srand_fuzz { $rng_seed = shift // 42; }
sub _rand      { $rng_seed = ( ( $rng_seed * 1103515245 + 12345 ) & 0x7FFFFFFF ); return $rng_seed / 0x7FFFFFFF; }
sub _int       { my ($max) = @_;                                                  return int( _rand() * ( $max // 10 ) ); }
sub _pick      { my @arr   = @_;                                                  return $arr[ _int( scalar @arr ) ]; }

# --- Type pool ---
my @TYPES = qw(Int String Any Bool);
my @VARS  = map { '$' . $_ } qw(x y z val result tmp i n acc a b c s t counter flag done data item);
my @OPS   = qw(+ - * / % == != < > <= >= && ||);

# --- Expressions ---
sub random_expr {
    my ($depth) = @_;
    $depth //= 0;
    return _random_leaf() if $depth >= 4 || _rand() < 0.3;
    my $choice = _int(7);
    if    ( $choice == 0 ) { return _random_leaf() }
    elsif ( $choice == 1 ) { return _random_binop($depth) }
    elsif ( $choice == 2 ) { return _random_unary($depth) }
    elsif ( $choice == 3 ) { return _random_ternary($depth) }
    elsif ( $choice == 4 ) { return _random_call($depth) }
    elsif ( $choice == 5 ) { return _random_array($depth) }
    else                   { return _random_leaf() }
}

sub _random_leaf {
    my $choice = _int(5);
    if    ( $choice == 0 ) { return Brocken::AST::Expr::Const->new( value => _int(1000),                          type => 'Int' ) }
    elsif ( $choice == 1 ) { return Brocken::AST::Expr::Const->new( value => _pick(qw(hello world test done 42)), type => 'String' ) }
    elsif ( $choice == 2 ) { return Brocken::AST::Expr::Const->new( value => _int(2) ? 'true' : 'false',          type => 'Int' ) }
    elsif ( $choice == 3 ) { return Brocken::AST::Expr::Var->new( name => _pick(@VARS) ) }
    else                   { return Brocken::AST::Expr::Const->new( value => 0, type => 'Int' ) }
}

sub _random_binop {
    my ($depth) = @_;
    return Brocken::AST::Expr::BinOp->new( op => _pick(@OPS), left => random_expr( $depth + 1 ), right => random_expr( $depth + 1 ), );
}

sub _random_unary {
    my ($depth) = @_;
    return Brocken::AST::Expr::UnaryOp->new( op => '!', expr => random_expr( $depth + 1 ) );
}

sub _random_ternary {
    my ($depth) = @_;
    return Brocken::AST::Expr::Ternary->new( cond => random_expr( $depth + 1 ), then => random_expr( $depth + 1 ), else => random_expr( $depth + 1 ),
    );
}

sub _random_call {
    my ($depth) = @_;
    my $name = _pick(qw(say print transfer));
    my @args;
    push @args, random_expr( $depth + 1 ) for ( 1 .. 1 + _int(2) );
    return Brocken::AST::Expr::Call->new( name => $name, args => \@args );
}

sub _random_array {
    my ($depth) = @_;
    my @elements;
    push @elements, random_expr( $depth + 1 ) for ( 1 .. _int(4) );
    return Brocken::AST::Expr::ArrayLiteral->new( elements => \@elements );
}

# --- Statements ---
sub random_stmt {
    my ($depth) = @_;
    $depth //= 0;
    return random_block($depth) if $depth >= 6;
    my $choice = _int(9);
    if    ( $choice == 0 ) { return random_var_decl() }
    elsif ( $choice == 1 ) { return random_assignment() }
    elsif ( $choice == 2 ) { return random_if($depth) }
    elsif ( $choice == 3 ) { return random_while($depth) }
    elsif ( $choice == 4 ) { return random_return() }
    elsif ( $choice == 5 ) { return _random_exit() }
    elsif ( $choice == 6 ) { return _random_say() }
    elsif ( $choice == 7 ) { return random_block($depth) }
    else                   { return random_var_decl() }
}

sub random_var_decl {
    return Brocken::AST::Stmt::VarDecl->new( name => _pick(@VARS), type => _pick(@TYPES), value => random_expr(), );
}

sub random_assignment {
    return Brocken::AST::Stmt::Assignment->new( name => _pick(@VARS), value => random_expr(), );
}

sub random_if {
    my ($depth) = @_;
    my $else = _rand() < 0.3 ? random_block( $depth + 1 ) : undef;
    return Brocken::AST::Stmt::If->new( condition => random_expr(), then_block => random_block( $depth + 1 ), else_block => $else, );
}

sub random_while {
    my ($depth) = @_;
    return Brocken::AST::Stmt::While->new( condition => random_expr(), body => random_block( $depth + 1 ), );
}

sub random_return {
    my $has_expr = _rand() < 0.7;
    return Brocken::AST::Stmt::Return->new( expr => $has_expr ? random_expr() : undef, );
}

sub _random_exit {
    return Brocken::AST::Stmt::Exit->new( expr => _rand() < 0.7 ? random_expr() : undef, );
}

sub _random_say {
    return Brocken::AST::Expr::Call->new( name => _pick(qw(say print)), args => [ random_expr() ], );
}

sub random_block {
    my ($depth) = @_;
    $depth //= 0;
    my @stmts;
    push @stmts, random_stmt( $depth + 1 ) for ( 1 .. 1 + _int(5) );
    return Brocken::AST::Stmt::Block->new( statements => \@stmts );
}

# --- High-level constructs ---
sub random_sub {
    my $name       = _pick(qw(foo bar helper calc run process handle));
    my $num_params = _int(3);
    my @params;
    for ( 1 .. $num_params ) {
        push @params, { name => _pick(@VARS), type => _pick(@TYPES) };
    }
    return Brocken::AST::OOP::Method->new( name => $name, params => \@params, body => random_block(), );
}

sub random_class {
    my $name = _pick(qw(User Item Foo Bar Config Handler));
    my @fields;
    my @methods;
    for ( 1 .. _int(3) ) {
        push @fields, Brocken::AST::OOP::FieldDecl->new( name => _pick(@VARS), type => _pick(@TYPES), );
    }
    for ( 1 .. _int(2) ) {
        my $m = Brocken::AST::OOP::Method->new( name => _pick(qw(get set reset init)), params => [], body => random_block(), );
        push @methods, $m;
    }
    return Brocken::AST::OOP::ClassDecl->new( name => $name, fields => \@fields, methods => \@methods, );
}

sub random_fiber {
    return Brocken::AST::Async::FiberBlock->new( params => [], body => random_block(), );
}

# --- Program generation ---
sub random_program {
    my ( $include_sub, $include_class ) = @_;
    $include_sub   //= _rand() < 0.4;
    $include_class //= _rand() < 0.2;
    my @nodes;
    push @nodes, random_sub()   if $include_sub;
    push @nodes, random_class() if $include_class;
    push @nodes, random_stmt() for ( 1 .. 1 + _int(10) );
    return \@nodes;
}

# --- AST utilities ---
sub ast_size {
    my ($node) = @_;
    return 0 unless ref $node;
    my $count = 1;
    if ( $node->can('statements') )                      { $count += ast_size($_) for @{ $node->statements } }
    if ( $node->can('body') )                            { $count += ast_size( $node->body ) }
    if ( $node->can('then_block') )                      { $count += ast_size( $node->then_block ) }
    if ( $node->can('else_block') && $node->else_block ) { $count += ast_size( $node->else_block ) }
    if ( $node->can('condition') )                       { $count += ast_size( $node->condition ) }
    if ( $node->can('expr') )                            { $count += ast_size( $node->expr ) }
    if ( $node->can('left') )                            { $count += ast_size( $node->left ) }
    if ( $node->can('right') )                           { $count += ast_size( $node->right ) }
    if ( $node->can('value') )                           { $count += ast_size( $node->value ) }
    if ( $node->can('args') )                            { $count += ast_size($_) for @{ $node->args } }
    if ( $node->can('elements') )                        { $count += ast_size($_) for @{ $node->elements } }
    return $count;
}

sub count_nodes {
    my ( $node, $class ) = @_;
    return 0 unless ref $node;
    my $count = ref($node) eq $class ? 1 : 0;
    if ( $node->can('statements') )                      { $count += count_nodes( $_,                $class ) for @{ $node->statements } }
    if ( $node->can('body') )                            { $count += count_nodes( $node->body,       $class ) }
    if ( $node->can('then_block') )                      { $count += count_nodes( $node->then_block, $class ) }
    if ( $node->can('else_block') && $node->else_block ) { $count += count_nodes( $node->else_block, $class ) }
    if ( $node->can('condition') )                       { $count += count_nodes( $node->condition,  $class ) }
    if ( $node->can('expr') )                            { $count += count_nodes( $node->expr,       $class ) }
    if ( $node->can('left') )                            { $count += count_nodes( $node->left,       $class ) }
    if ( $node->can('right') )                           { $count += count_nodes( $node->right,      $class ) }
    if ( $node->can('value') )                           { $count += count_nodes( $node->value,      $class ) }
    if ( $node->can('args') )                            { $count += count_nodes( $_, $class ) for @{ $node->args } }
    if ( $node->can('elements') )                        { $count += count_nodes( $_, $class ) for @{ $node->elements } }
    return $count;
}

sub ast_equals {
    my ( $a, $b ) = @_;
    return 0 if ref($a) ne ref($b);
    if ( $a isa 'Brocken::AST::Expr::Const' ) {
        return $a->value eq $b->value && $a->type eq $b->type;
    }
    if ( $a isa 'Brocken::AST::Expr::Var' ) {
        return $a->name eq $b->name;
    }
    if ( $a isa 'Brocken::AST::Expr::BinOp' ) {
        return $a->op eq $b->op && ast_equals( $a->left, $b->left ) && ast_equals( $a->right, $b->right );
    }
    if ( $a isa 'Brocken::AST::Expr::UnaryOp' ) {
        return $a->op eq $b->op && ast_equals( $a->expr, $b->expr );
    }
    if ( $a isa 'Brocken::AST::Expr::Ternary' ) {
        return ast_equals( $a->cond, $b->cond ) && ast_equals( $a->then, $b->then ) && ast_equals( $a->else, $b->else );
    }
    if ( $a isa 'Brocken::AST::Stmt::Block' ) {
        return 0 if @{ $a->statements } != @{ $b->statements };
        return ast_equals( $_, $b->statements->[$_] ) for ( 0 .. $#{ $a->statements } );
        return 1;
    }
    if ( $a isa 'Brocken::AST::Stmt::VarDecl' ) {
        return $a->name eq $b->name && $a->type eq $b->type && ast_equals( $a->value, $b->value );
    }
    if ( $a isa 'Brocken::AST::Stmt::Assignment' ) {
        return $a->name eq $b->name && ast_equals( $a->value, $b->value );
    }
    if ( $a isa 'Brocken::AST::Stmt::If' ) {
        return ast_equals( $a->condition, $b->condition ) &&
            ast_equals( $a->then_block, $b->then_block ) &&
            ast_equals( $a->else_block, $b->else_block );
    }
    if ( $a isa 'Brocken::AST::Stmt::While' ) {
        return ast_equals( $a->condition, $b->condition ) && ast_equals( $a->body, $b->body );
    }
    if ( $a isa 'Brocken::AST::Stmt::Return' ) {
        return ast_equals( $a->expr, $b->expr );
    }
    if ( $a isa 'Brocken::AST::Expr::Call' ) {
        return $a->name eq $b->name && @{ $a->args } == @{ $b->args } && ast_equals( $_, $b->args->[$_] ) for ( 0 .. $#{ $a->args } );
        return 1;
    }
    return ref($a) eq ref($b);
}
1;
