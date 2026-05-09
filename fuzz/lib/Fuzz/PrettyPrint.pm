package Fuzz::PrettyPrint;
use v5.40;
use strict;
use warnings;
use Exporter 'import';
our @EXPORT_OK = qw(ast_to_source);

sub ast_to_source {
    my ( $node, $indent ) = @_;
    $indent //= 0;
    my $pad = '    ' x $indent;
    my $cls = ref($node) or return '';

    # --- Expressions ---
    if ( $cls eq 'Brocken::AST::Expr::Const' ) {
        return $node->type eq 'String' ? qq{"} . $node->value . qq{"} : $node->value;
    }
    if ( $cls eq 'Brocken::AST::Expr::Var' ) {
        return $node->name;
    }
    if ( $cls eq 'Brocken::AST::Expr::BinOp' ) {
        my $l  = ast_to_source( $node->left,  $indent );
        my $r  = ast_to_source( $node->right, $indent );
        my $op = $node->op;
        $op = '||' if $op eq 'or';
        $op = '&&' if $op eq 'and';
        $op = '->' if $op eq 'deref';
        return "($l $op $r)";
    }
    if ( $cls eq 'Brocken::AST::Expr::UnaryOp' ) {
        return '!' . ast_to_source( $node->expr, $indent );
    }
    if ( $cls eq 'Brocken::AST::Expr::Ternary' ) {
        my $c = ast_to_source( $node->cond, $indent );
        my $t = ast_to_source( $node->then, $indent );
        my $e = ast_to_source( $node->else, $indent );
        return "($c ? $t : $e)";
    }
    if ( $cls eq 'Brocken::AST::Expr::Call' ) {
        my @args = map { ast_to_source( $_, $indent ) } @{ $node->args };
        return $node->name . '(' . join( ', ', @args ) . ')';
    }
    if ( $cls eq 'Brocken::AST::Expr::AnonCall' ) {
        my $inv  = ast_to_source( $node->invocant, $indent );
        my @args = map { ast_to_source( $_, $indent ) } @{ $node->args };
        return "$inv->(" . join( ', ', @args ) . ')';
    }
    if ( $cls eq 'Brocken::AST::Expr::ArrayLiteral' ) {
        my @el = map { ast_to_source( $_, $indent ) } @{ $node->elements };
        return '[' . join( ', ', @el ) . ']';
    }

    # --- Statements ---
    if ( $cls eq 'Brocken::AST::Stmt::Block' ) {
        my @stmts = map { ast_to_source( $_, $indent + 1 ) } @{ $node->statements };
        return "{\n" . join( ";\n", @stmts ) . ";\n$pad}";
    }
    if ( $cls eq 'Brocken::AST::Stmt::VarDecl' ) {
        my $type = $node->type eq 'Any' ? '' : "$node->type ";
        my $val  = ast_to_source( $node->value, $indent );
        return "${pad}my ${type}$node->name = $val";
    }
    if ( $cls eq 'Brocken::AST::Stmt::Assignment' ) {
        my $val = ast_to_source( $node->value, $indent );
        return "${pad}$node->name = $val";
    }
    if ( $cls eq 'Brocken::AST::Stmt::If' ) {
        my $c = ast_to_source( $node->condition,  $indent );
        my $t = ast_to_source( $node->then_block, $indent );
        if ( $node->else_block ) {
            my $e = ast_to_source( $node->else_block, $indent );
            return "${pad}if ($c)\n$t\n${pad}else\n$e";
        }
        return "${pad}if ($c)\n$t";
    }
    if ( $cls eq 'Brocken::AST::Stmt::While' ) {
        my $c = ast_to_source( $node->condition, $indent );
        my $b = ast_to_source( $node->body,      $indent );
        return "${pad}while ($c)\n$b";
    }
    if ( $cls eq 'Brocken::AST::Stmt::Return' ) {
        return $node->expr ? "${pad}return " . ast_to_source( $node->expr, $indent ) : "${pad}return";
    }
    if ( $cls eq 'Brocken::AST::Stmt::Exit' ) {
        return $node->expr ? "${pad}exit " . ast_to_source( $node->expr, $indent ) : "${pad}exit";
    }
    if ( $cls eq 'Brocken::AST::Stmt::Defer' ) {
        return "${pad}defer " . ast_to_source( $node->block, $indent );
    }

    # --- OOP ---
    if ( $cls eq 'Brocken::AST::OOP::ClassDecl' ) {
        my @lines = ("${pad}class $node->name {");
        for my $f ( @{ $node->fields } ) {
            my $fp = '    ' x ( $indent + 1 );
            push @lines, "${fp}field " . ( $f->type ne 'Any' ? "$f->type " : '' ) . "$f->name;";
        }
        for my $m ( @{ $node->methods } ) {
            push @lines, ast_to_source( $m, $indent + 1 );
        }
        push @lines, "$pad}";
        return join( "\n", @lines );
    }
    if ( $cls eq 'Brocken::AST::OOP::Method' ) {
        my @params;
        for my $p ( @{ $node->params } ) {
            push @params, ( $p->{type} ne 'Any' ? "$p->{type} " : '' ) . $p->{name};
        }
        my $body = ast_to_source( $node->body, $indent );
        my $p    = '    ' x $indent;
        return "${p}sub $node->name(" . join( ', ', @params ) . ")\n$body";
    }
    if ( $cls eq 'Brocken::AST::OOP::MethodCall' ) {
        my $inv  = ast_to_source( $node->invocant, $indent );
        my @args = map { ast_to_source( $_, $indent ) } @{ $node->args };
        return "$inv->$node->name(" . join( ', ', @args ) . ')';
    }
    if ( $cls eq 'Brocken::AST::OOP::AnonSub' ) {
        my @params;
        for my $p ( @{ $node->params } ) {
            push @params, ( $p->{type} ne 'Any' ? "$p->{type} " : '' ) . $p->{name};
        }
        return "sub (" . join( ', ', @params ) . ') ' . ast_to_source( $node->body, $indent );
    }

    # --- Async ---
    if ( $cls eq 'Brocken::AST::Async::FiberBlock' ) {
        my @params;
        for my $p ( @{ $node->params } ) {
            push @params, ( $p->{type} ne 'Any' ? "$p->{type} " : '' ) . $p->{name};
        }
        my $body = ast_to_source( $node->body, $indent );
        my $p    = '    ' x $indent;
        return "${p}fiber (" . join( ', ', @params ) . ")\n$body";
    }
    if ( $cls eq 'Brocken::AST::Async::Yield' ) {
        return $node->expr ? "yield " . ast_to_source( $node->expr, $indent ) : "yield";
    }
    return "# Unknown: $cls";
}
1;
