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
        my our state class method field return exit fiber yield
        if else while for map say print Int String Any];

    method lex() {
        my @tokens;
        my $length = length($source);
        while ( $pos < $length ) {
            my $remaining = substr( $source, $pos );
            if ( $remaining =~ /^(\s+)/ ) { $self->_advance( length($1) ); next; }
            if ( $remaining =~ /^(#[^\n]*)/ ) { $self->_advance( length($1) ); next; }
            if ( $remaining =~ /^(\d+)/ ) { push @tokens, $self->_make_token( 'NUM', $1 ); $self->_advance( length($1) ); next; }

            # Replaced complex string regex with simple character-by-character scan for robustness against emojis
            if ( $remaining =~ /^"([^"]*)"/s ) {
                my $val = $1;
                $val =~ s/\\n/\n/g;
                $val =~ s/\\"/"/g;
                push @tokens, $self->_make_token( 'STRING', $val );
                $self->_advance( length($&) );
                next;
            }
            if ( $remaining =~ /^([\$@%]?[a-zA-Z_]\w*)/ ) {
                my $val  = $1;
                my $type = 'IDENT';
                if    ( $val =~ /^[\$@%]/ ) { $type = 'VAR'; }
                elsif ( $KEYWORDS{$val} )   { $type = 'KEYWORD'; }
                push @tokens, $self->_make_token( $type, $val );
                $self->_advance( length($val) );
                next;
            }
            if ( $remaining =~ /^(==|!=|<=|>=|=>|->)/ ) { push @tokens, $self->_make_token( 'OP', $1 ); $self->_advance( length($1) ); next; }
            # Included literal '.' as a valid operator so comment skips/etc won't break if it somehow falls through
            if ( $remaining =~ /^([+\-*\/=<>\[\].])/ )  { push @tokens, $self->_make_token( 'OP', $1 ); $self->_advance(1);            next; }
            if ( $remaining =~ /^([{};(),\[\]])/ )      { push @tokens, $self->_make_token( $1,   $1 ); $self->_advance(1);            next; }

            # If all else fails, just skip the char instead of crashing the lexer on emojis (for now)
            $self->_advance(1);
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
