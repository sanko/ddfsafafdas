use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
use Brocken::Core::Lexer;
use Brocken::Core::Parser;

sub parse {
    my ($source) = @_;
    my $tokens = Brocken::Core::Lexer->new( source => $source )->lex();
    return Brocken::Core::Parser->new( tokens => $tokens )->parse();
}
subtest 'For loop with my' => sub {
    my $ast  = parse('for my $elem (@items) { say $elem; }');
    my $node = $ast->[0];
    ok $node->isa('Brocken::AST::Stmt::For'), 'for my isa For';
    is $node->var, '$elem', 'for my $elem';
    ok $node->is_my, 'is_my is true';
};
subtest 'For loop with explicit var' => sub {
    my $ast  = parse('for $item (1..10) { say $item; }');
    my $node = $ast->[0];
    is $node->var, '$item', 'for $item';
};
subtest 'For loop default var' => sub {
    my $ast  = parse('for (@arr) { say $_; }');
    my $node = $ast->[0];
    ok $node->isa('Brocken::AST::Stmt::For'), 'for isa For';
    is $node->var, '$_', 'for default var is $_';
    ok !$node->is_my,                                 'is_my is false';
    ok $node->body->isa('Brocken::AST::Stmt::Block'), 'body is Block';
};
subtest 'Next/Last/Redo' => sub {
    for my $kw (qw(next last redo)) {
        my $ast   = parse("$kw;");
        my $node  = $ast->[0];
        my $class = "Brocken::AST::Stmt::" . ucfirst($kw);
        ok $node->isa($class), "$kw parsed correctly";
    }
};
subtest 'Our declaration' => sub {
    my $ast  = parse('our Int $x = 42;');
    my $node = $ast->[0];
    ok $node->isa('Brocken::AST::Stmt::OurDecl'), 'our isa OurDecl';
    is $node->name, '$x',  'our $x';
    is $node->type, 'Int', 'our type Int';
};
subtest 'State declaration' => sub {
    my $ast  = parse('state Int $count = 0;');
    my $node = $ast->[0];
    ok $node->isa('Brocken::AST::Stmt::StateDecl'), 'state isa StateDecl';
    is $node->name, '$count', 'state $count';
};
subtest 'Return with expression' => sub {
    my $ast  = parse('return 42;');
    my $node = $ast->[0];
    ok $node->isa('Brocken::AST::Stmt::Return'), 'return isa Return';
    ok $node->expr,                              'return has expression';
    is $node->expr->value, 42, 'return value 42';
};
subtest 'Return without expression' => sub {
    my $ast  = parse('return;');
    my $node = $ast->[0];
    is $node->expr, undef, 'return undef without expr';
};
subtest 'Exit' => sub {
    my $ast  = parse('exit 0;');
    my $node = $ast->[0];
    ok $node->isa('Brocken::AST::Stmt::Exit'), 'exit isa Exit';
};
subtest 'Try/Catch/Finally' => sub {
    my $ast  = parse('try { say 1; } catch ($e) { say 2; } finally { say 3; }');
    my $node = $ast->[0];
    ok $node->isa('Brocken::AST::Exception::TryCatch'),        'try isa TryCatch';
    ok $node->try_block->isa('Brocken::AST::Stmt::Block'),     'try_block is Block';
    ok $node->catch_block->isa('Brocken::AST::Stmt::Block'),   'catch_block is Block';
    ok $node->finally_block->isa('Brocken::AST::Stmt::Block'), 'finally_block is Block';
    is $node->catch_var->{value}, '$e', 'catch var $e';
};
subtest 'Try/Catch without finally' => sub {
    my $ast  = parse('try { die "err"; } catch ($err) { say $err; }');
    my $node = $ast->[0];
    ok $node->isa('Brocken::AST::Exception::TryCatch'), 'try isa TryCatch';
    is $node->finally_block, undef, 'no finally block';
};
subtest 'Die statement' => sub {
    my $ast  = parse('die "error message";');
    my $node = $ast->[0];
    ok $node->isa('Brocken::AST::Exception::Die'), 'die isa Die';
};
subtest 'Unless' => sub {
    my $ast  = parse('unless ($x) { say "no"; }');
    my $node = $ast->[0];
    ok $node->isa('Brocken::AST::Stmt::If'),                 'unless isa If';
    ok $node->condition->isa('Brocken::AST::Expr::UnaryOp'), 'condition is UnaryOp';
    is $node->condition->op, '!',   'unless uses negation';
    is $node->else_block,    undef, 'no else for unless';
};
subtest 'Until' => sub {
    my $ast  = parse('until ($done) { next; }');
    my $node = $ast->[0];
    ok $node->isa('Brocken::AST::Stmt::While'),              'until isa While';
    ok $node->condition->isa('Brocken::AST::Expr::UnaryOp'), 'condition is UnaryOp';
    is $node->condition->op, '!', 'until uses negation';
};
subtest 'Defined-or operator //' => sub {
    my $ast  = parse('$x // 42;');
    my $node = $ast->[0];
    ok $node->isa('Brocken::AST::Expr::BinOp'), '// isa BinOp';
    is $node->op, '//', 'defined-or op';
};
subtest 'String comparison operators' => sub {
    for my $op (qw(eq ne lt gt le ge)) {
        my $ast  = parse("\$x $op \$y;");
        my $node = $ast->[0];
        ok $node->isa('Brocken::AST::Expr::BinOp'), "string cmp $op isa BinOp";
        is $node->op, $op, "string cmp $op";
    }
};
subtest 'Range operator ..' => sub {
    my $ast  = parse('1..10;');
    my $node = $ast->[0];
    ok $node->isa('Brocken::AST::Expr::BinOp'), '.. isa BinOp';
    is $node->op, '..', 'range ..';
};
subtest 'Yada operator' => sub {
    my $ast  = parse('...;');
    my $node = $ast->[0];
    ok $node->isa('Brocken::AST::Stmt::Yada'), '... isa Yada';
};
subtest 'Hash literal' => sub {
    my $ast  = parse('my $h = { key => "value", name => "test" };');
    my $node = $ast->[0];
    ok $node->isa('Brocken::AST::Stmt::VarDecl'),            'hash assign is VarDecl';
    ok $node->value->isa('Brocken::AST::Expr::HashLiteral'), 'value is HashLiteral';
    is scalar( @{ $node->value->pairs } ), 2, 'two hash pairs';
};
subtest 'Array literal' => sub {
    my $ast  = parse('[1, 2, 3];');
    my $node = $ast->[0];
    ok $node->isa('Brocken::AST::Expr::ArrayLiteral'), 'array isa ArrayLiteral';
    is scalar( @{ $node->elements } ), 3, 'three array elements';
};
subtest 'Use statement' => sub {
    my $ast  = parse('use Math::Utils;');
    my $node = $ast->[0];
    ok $node->isa('Brocken::AST::Stmt::Use'), 'use isa Use';
    is $node->package, 'Math::Utils', 'use package with ::';
};
subtest 'Require statement' => sub {
    my $ast  = parse('require JSON;');
    my $node = $ast->[0];
    ok $node->isa('Brocken::AST::Stmt::Require'), 'require isa Require';
    is $node->package, 'JSON', 'require package';
};
subtest 'Anonymous sub' => sub {
    my $ast = parse('my $f = sub (Int $x) { return $x + 1; };');
    my $vd  = $ast->[0];
    ok $vd->isa('Brocken::AST::Stmt::VarDecl'),       'anon sub in VarDecl';
    ok $vd->value->isa('Brocken::AST::OOP::AnonSub'), 'value is AnonSub';
};
subtest 'Fiber block' => sub {
    my $ast = parse('my $f = fiber { yield 42; };');
    my $vd  = $ast->[0];
    ok $vd->isa('Brocken::AST::Stmt::VarDecl'),            'fiber in VarDecl';
    ok $vd->value->isa('Brocken::AST::Async::FiberBlock'), 'value is FiberBlock';
};
subtest 'Class with attributes' => sub {
    my $ast  = parse('class Foo :attr(bar) { field Int $x; method get() { return $x; } }');
    my $node = $ast->[0];
    ok $node->isa('Brocken::AST::OOP::ClassDecl'), 'class isa ClassDecl';
    is scalar( @{ $node->attributes } ), 1, 'one class attribute';
};
subtest 'Native declaration' => sub {
    my $ast  = parse('native "kernel32.dll", "Sleep", "void(int)";');
    my $node = $ast->[0];
    ok $node->isa('Brocken::AST::NativeDecl'), 'native isa NativeDecl';
    is $node->library, 'kernel32.dll', 'native library';
    is $node->name,    'Sleep',        'native name';
};
subtest 'Exists expression' => sub {
    my $ast  = parse('exists $hash{key};');
    my $node = $ast->[0];
    ok $node->isa('Brocken::AST::Expr::Exists'), 'exists isa Exists';
};
subtest 'Delete expression' => sub {
    my $ast  = parse('delete $hash{key};');
    my $node = $ast->[0];
    ok $node->isa('Brocken::AST::Expr::Delete'), 'delete isa Delete';
};
subtest 'Assignment to array index' => sub {
    my $ast  = parse('$arr[0] = 42;');
    my $node = $ast->[0];
    ok $node->isa('Brocken::AST::Stmt::Assignment'),      'arr assign isa Assignment';
    ok $node->name->isa('Brocken::AST::Expr::IndexExpr'), 'target is IndexExpr';
};
subtest 'Assignment to hash key' => sub {
    my $ast  = parse('$hash{key} = "val";');
    my $node = $ast->[0];
    ok $node->isa('Brocken::AST::Stmt::Assignment'),      'hash assign isa Assignment';
    ok $node->name->isa('Brocken::AST::Expr::IndexExpr'), 'target is IndexExpr';
};
subtest 'Empty block' => sub {
    my $ast  = parse('{}');
    my $node = $ast->[0];
    ok $node->isa('Brocken::AST::Stmt::Block'), 'block isa Block';
    is scalar( @{ $node->statements } ), 0, 'empty block';
};
subtest 'Multiple statements' => sub {
    my $ast = parse('my $x = 1; my $y = 2; my $z = $x + $y;');
    is scalar(@$ast), 3, 'three statements parsed';
};
subtest 'Map expression' => sub {
    my $ast  = parse('map { $_ * 2 } @items;');
    my $node = $ast->[0];
    ok $node->isa('Brocken::AST::Stmt::Map'), 'map isa Map';
};
done_testing;

