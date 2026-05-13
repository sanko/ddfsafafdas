use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
use Brocken::Lexer;
subtest 'Basic Tokenization' => sub {
    my $source = 'my Int $x = 42; say "hello world";';
    my $lexer  = Brocken::Lexer->new( source => $source );
    my $tokens = $lexer->lex();
    is( scalar @$tokens,     10,        'Correct number of tokens' );
    is( $tokens->[0]{type},  'KEYWORD', 'my' );
    is( $tokens->[1]{type},  'KEYWORD', 'Int' );
    is( $tokens->[2]{type},  'VAR',     '$x' );
    is( $tokens->[3]{value}, '=',       'assignment' );
    is( $tokens->[4]{type},  'NUM',     '42' );
    is( $tokens->[5]{value}, ';',       'semicolon' );
    is( $tokens->[6]{type},  'KEYWORD', 'say' );
    is( $tokens->[7]{type},  'STRING',  'string literal' );
    is( $tokens->[8]{value}, ';',       'final semicolon' );
    is( $tokens->[9]{type},  'EOF',     'EOF' );
};
subtest 'UTF-8 and Emoji' => sub {
    my $source = 'my $🔥 = "😀";';
    my $lexer  = Brocken::Lexer->new( source => $source );
    my $tokens = $lexer->lex();

    # 0: my, 1: $🔥, 2: =, 3: "😀", 4: ;, 5: EOF
    is( $tokens->[1]{value}, '$🔥', 'Emoji variable name' );
    is( $tokens->[3]{value}, '😀',  'Emoji string content' );
};
subtest 'Complex Operators' => sub {
    my $source = '$x == 10 && $y != 20 || !$z;';
    my $lexer  = Brocken::Lexer->new( source => $source );
    my $tokens = $lexer->lex();
    my @ops    = grep { $_->{type} eq 'OP' } @$tokens;
    is( [ map { $_->{value} } @ops ], [qw( == && != || ! )], 'Correct operator sequence' );
};
subtest 'Comments' => sub {
    my $source = 'my $x = 10; # this is a comment
say $x;';
    my $lexer  = Brocken::Lexer->new( source => $source );
    my $tokens = $lexer->lex();

    # 0: my, 1: $x, 2: =, 3: 10, 4: ;, 5: say, 6: $x, 7: ;, 8: EOF
    is( $tokens->[4]{value}, ';',   'Tokens before comment' );
    is( $tokens->[5]{value}, 'say', 'Tokens after comment' );
};
done_testing;
