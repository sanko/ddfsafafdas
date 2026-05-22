use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
use Brocken::Compiler;
subtest 'Scope creation and symbol resolution' => sub {
    my $outer = Brocken::Scope->new();
    $outer->define( '$x', 'Int' );
    ok $outer->has_local_symbol('$x'), 'outer has $x';
    my $inner = Brocken::Scope->new( parent => $outer );
    $inner->define( '$y', 'String' );
    ok $inner->has_local_symbol('$y'),  'inner has $y';
    ok !$inner->has_local_symbol('$x'), 'inner does not directly have $x';
    my $resolved = $inner->resolve('$x');
    ok $resolved, 'inner resolves $x via parent';
    is $resolved->name, '$x',  'resolved name is $x';
    is $resolved->type, 'Int', 'resolved type is Int';
};
subtest 'Scope redeclaration error' => sub {
    my $s = Brocken::Scope->new();
    $s->define( '$x', 'Int' );
    ok $s->has_local_symbol('$x'), '$x defined once';
    eval { $s->define( '$x', 'String' ) };
    ok $@, 'redeclaration causes error';
};
subtest 'Scope resolution failure' => sub {
    my $s   = Brocken::Scope->new();
    my $res = $s->resolve('$nonexistent');
    is $res, undef, 'unresolved symbol returns undef';
};
subtest 'Symbol construction' => sub {
    my $sym = Brocken::Symbol->new( name => '$counter', type => 'Int', is_state => 1, stack_offset => 16, );
    is $sym->name, '$counter', 'symbol name';
    is $sym->type, 'Int',      'symbol type';
    ok $sym->is_state, 'symbol is_state';
    is $sym->stack_offset,  16,    'symbol stack_offset';
    is $sym->shadow_offset, undef, 'default shadow_offset undef';
};
subtest 'Nested scope chain' => sub {
    my $g = Brocken::Scope->new();
    $g->define( '$global', 'Int', 0, undef, 0 );
    my $outer = Brocken::Scope->new( parent => $g );
    $outer->define( '$outer_var', 'String' );
    my $inner = Brocken::Scope->new( parent => $outer );
    $inner->define( '$inner_var', 'Bool' );
    is $inner->resolve('$global')->name,    '$global',    'inner resolves $global';
    is $inner->resolve('$outer_var')->name, '$outer_var', 'inner resolves $outer_var';
    is $inner->resolve('$inner_var')->name, '$inner_var', 'inner resolves $inner_var';
    ok !$outer->resolve('$inner_var'), 'outer cannot resolve inner var';
};
done_testing;
