use v5.40;
use utf8;
use feature 'class';
use Test2::V0;
no warnings 'portable', 'experimental::class', 'qw';
use lib 'lib', '../../lib';
use Brocken::Lexer;

sub lex_tokens {
    my ($source) = @_;
    return Brocken::Lexer->new( source => $source )->lex();
}
subtest 'For loop keywords' => sub {
    my $tokens = lex_tokens('for');
    is $tokens->[0]{type},  'KEYWORD', 'for is KEYWORD';
    is $tokens->[0]{value}, 'for',     'for value';
};
subtest 'Loop control keywords' => sub {
    for my $kw (qw(next last redo)) {
        my $tokens = lex_tokens($kw);
        is $tokens->[0]{type}, 'KEYWORD', "$kw is KEYWORD";
    }
};
subtest 'Exception handling keywords' => sub {
    for my $kw (qw(try catch finally die)) {
        my $tokens = lex_tokens($kw);
        is $tokens->[0]{type}, 'KEYWORD', "$kw is KEYWORD";
    }
};
subtest 'Boolean literals' => sub {
    for my $kw (qw(true false undef)) {
        my $tokens = lex_tokens($kw);
        is $tokens->[0]{type}, 'KEYWORD', "$kw is KEYWORD";
    }
};
subtest 'Type keywords' => sub {
    for my $kw (qw(Int String Any Bool Class Fiber Array Fun Pointer Struct Callback)) {
        my $tokens = lex_tokens($kw);
        is $tokens->[0]{type}, 'KEYWORD', "$kw is KEYWORD";
    }
};
subtest 'Range operators' => sub {
    my $tokens = lex_tokens('.. ...');
    is $tokens->[0]{value}, '..',  'range ..';
    is $tokens->[0]{type},  'OP',  '.. is OP';
    is $tokens->[1]{value}, '...', 'range ...';
    is $tokens->[1]{type},  'OP',  '... is OP';
};
subtest 'Defined-or operator' => sub {
    my $tokens = lex_tokens('//');
    is $tokens->[0]{value}, '//', 'defined-or operator';
    is $tokens->[0]{type},  'OP', '// is OP';
};
subtest 'Arrow operator' => sub {
    my $tokens = lex_tokens('->');
    is $tokens->[0]{value}, '->', 'arrow operator';
    is $tokens->[0]{type},  'OP', '-> is OP';
};
subtest 'Fat comma' => sub {
    my $tokens = lex_tokens('=>');
    is $tokens->[0]{value}, '=>', 'fat comma';
    is $tokens->[0]{type},  'OP', '=> is OP';
};
subtest 'String operators' => sub {
    for my $op (qw(eq ne lt gt le ge)) {
        my $tokens = lex_tokens($op);
        is $tokens->[0]{type}, 'KEYWORD', "$op is KEYWORD";
    }
};
subtest 'Namespace separator' => sub {
    my $tokens = lex_tokens('Foo::Bar');
    is $tokens->[0]{type},  'IDENT', 'Foo is IDENT';
    is $tokens->[1]{value}, '::',    ':: is OP';
    is $tokens->[2]{type},  'IDENT', 'Bar is IDENT';
};
subtest 'Single-quoted strings' => sub {
    my $tokens = lex_tokens("'hello world'");
    is $tokens->[0]{type},  'STRING',      'single-quoted string';
    is $tokens->[0]{value}, 'hello world', 'single-quoted content';
};
subtest 'Single-quoted string escape' => sub {
    my $tokens = lex_tokens("'it\\'s ok'");
    is $tokens->[0]{value}, "it's ok", 'escaped single quote';
};
subtest 'Special variables' => sub {
    for my $v (qw($^X $$ $0 $^T)) {
        my $tokens = lex_tokens($v);
        is $tokens->[0]{type}, 'VAR', "$v is VAR";
    }
};
subtest 'Multiple operators sequence' => sub {
    my $tokens = lex_tokens('$x <= 10 && $y >= 20 || !$z');
    my @ops    = grep { $_->{type} eq 'OP' } @$tokens;
    is scalar(@ops),   5,    '5 operators in sequence';
    is $ops[0]{value}, '<=', 'first op is <=';
    is $ops[1]{value}, '&&', 'second op is &&';
    is $ops[2]{value}, '>=', 'third op is >=';
    is $ops[3]{value}, '||', 'fourth op is ||';
    is $ops[4]{value}, '!',  'fifth op is !';
};
subtest 'Comment handling' => sub {
    my $tokens = lex_tokens("# just a comment\nsay 42");
    is scalar(@$tokens),    3,     'comment skipped: say, NUM, EOF';
    is $tokens->[0]{value}, 'say', 'first token after comment';
};
subtest '#line directive' => sub {
    my $tokens = lex_tokens("#line 42 \"custom.brocken\"\nsay 1");
    is $tokens->[0]{line}, 42,               'line directive sets line to 42';
    is $tokens->[0]{file}, 'custom.brocken', 'line directive sets file';
};
subtest 'Empty source' => sub {
    my $tokens = lex_tokens('');
    is scalar(@$tokens),   1,     'only EOF for empty source';
    is $tokens->[0]{type}, 'EOF', 'EOF token';
};
subtest 'Punctuation tokens' => sub {
    for my $p (qw({ } ; ( ) ,)) {
        my $tokens = lex_tokens($p);
        is $tokens->[0]{value}, $p, "punctuation $p";
    }
};
subtest 'Interpolated string detection' => sub {
    my $tokens = lex_tokens('"Hello $name"');
    is $tokens->[0]{type}, 'INTERP_STRING', 'interpolated string detected';
};
done_testing;
