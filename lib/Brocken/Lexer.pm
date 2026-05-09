use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';

class Brocken::Lexer {
    field $source : param;
    field $pos  = 0;
    field $line = 1;
    field $col  = 1;
    my %KEYWORDS = map { $_ => 1 } qw[
        my our state
        class method field
        return exit
        sub
        fiber yield
        defer
        if else unless
        while for map
        say print
        Int String Any Bool
        true false undef
    ];

    method lex() {
        my @tokens;
        while ( $pos < length($source) ) {
            my $remaining = substr( $source, $pos );
            if ( $remaining =~ /^(\s+)/ )     { $self->_advance( length($1) ); next; }
            if ( $remaining =~ /^(#[^\n]*)/ ) { $self->_advance( length($1) ); next; }
            if ( $remaining =~ /^(\d+)/ ) { push @tokens, $self->_make_token( 'NUM', $1 ); $self->_advance( length($1) ); next; }

            # Robust String Lexing: Handles \" and \n and UTF-8 correctly
            if ( $remaining =~ /^"((?:[^"\\\$]|\\.|\$[\p{L}\p{S}_][\p{L}\p{S}\p{N}_]*)*)"/s ) {
                my $full_match = $&;
                my $content    = $1;
                my @parts;
                my $interp = 0;
                while ( $content =~ /((?:[^"\\\$]|\\.)*)(\$[\p{L}\p{S}_][\p{L}\p{S}\p{N}_]*)?/g ) {
                    my $lit = $1;
                    my $var = $2;
                    $lit =~ s/\\n/\n/g;
                    $lit =~ s/\\"/"/g;
                    $lit =~ s/\\\\/\\/g;
                    push @parts, [ STRING => $lit ] if length $lit;
                    if ( defined $var ) {
                        push @parts, [ VAR => $var ];
                        $interp = 1;
                    }
                }
                if ($interp) {
                    push @tokens, $self->_make_token( 'INTERP_STRING', \@parts );
                }
                else {
                    $content =~ s/\\n/\n/g;
                    $content =~ s/\\"/"/g;
                    $content =~ s/\\\\/\\/g;
                    push @tokens, $self->_make_token( 'STRING', $content );
                }
                $self->_advance( length($full_match) );
                next;
            }
            if ( $remaining =~ /^(==|!=|<=|>=|=>|->|&&|\|\||\/\/)/ ) {
                push @tokens, $self->_make_token( 'OP', $1 );
                $self->_advance( length($1) );
                next;
            }
            if ( $remaining =~ /^([+\-*\/=<>\[\].:!?])/ ) { push @tokens, $self->_make_token( 'OP', $1 ); $self->_advance(1); next; }
            if ( $remaining =~ /^([\$@%]?[\p{L}\p{S}_][\p{L}\p{S}\p{N}_]*)/ ) {
                my $val  = $1;
                my $type = $KEYWORDS{$val} ? 'KEYWORD' : ( $val =~ /^[\$@%]/ ? 'VAR' : 'IDENT' );
                push @tokens, $self->_make_token( $type, $val );
                $self->_advance( length($val) );
                next;
            }
            if ( $remaining =~ /^([{};(),])/ ) { push @tokens, $self->_make_token( $1, $1 ); $self->_advance(1); next; }
            die sprintf( "Lexer Error at L:%d C:%d: Unrecognized char '%s'\n", $line, $col, substr( $remaining, 0, 1 ) );
        }
        push @tokens, $self->_make_token( 'EOF', 'EOF' );
        return \@tokens;
    }

    method _advance($len) {
        my $str = substr( $source, $pos, $len );
        $pos += $len;
        while ( $str =~ /\n/g ) { $line++; $col = 1; }
        if ( $str =~ /([^\n]+)$/ ) { $col += length($1); }
    }
    method _make_token( $t, $v ) { return { type => $t, value => $v, line => $line, col => $col }; }
}
1;
__END__

=pod

=head1 NAME

Brocken::Lexer - Tokenizer for Brocken source code

=head1 DESCRIPTION

Converts Brocken source text into an array of token hashes. Each token contains C<type>, C<value>, C<line>, and C<col>.

Recognized token types: NUM, STRING, KEYWORD, IDENT, VAR, OP, single-char punctuation (C<{>, C<}>, C<;>, C<(>, C<)>,
C<,>), and EOF.

=head1 METHODS

=head2 lex

  my $tokens = Brocken::Lexer->new( source => $source )->lex();

Returns an arrayref of token hashrefs.

=cut
