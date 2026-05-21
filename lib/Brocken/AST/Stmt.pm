package Brocken::AST::Stmt {
    use v5.40;
    use feature 'class';
    no warnings 'experimental::class';
    #
    class Brocken::AST::Stmt::Block : isa(Brocken::AST::Node) { field $statements : param : reader; }

    class Brocken::AST::Stmt::VarDecl : isa(Brocken::AST::Node)
    { field $name : param : reader; field $type : param : reader; field $value : param : reader; }

    class Brocken::AST::Stmt::OurDecl : isa(Brocken::AST::Node)
    { field $name : param : reader; field $type : param : reader; field $value : param : reader; }

    class Brocken::AST::Stmt::StateDecl : isa(Brocken::AST::Node)
    { field $name : param : reader; field $type : param : reader; field $value : param : reader; }

    class Brocken::AST::Stmt::Assignment : isa(Brocken::AST::Node) { field $name : param : reader; field $value : param : reader; }

    class Brocken::AST::Stmt::If : isa(Brocken::AST::Node)
    { field $condition : param : reader; field $then_block : param : reader; field $else_block : param : reader = undef; }

    class Brocken::AST::Stmt::While : isa(Brocken::AST::Node) { field $condition : param : reader; field $body : param : reader; }

    class Brocken::AST::Stmt::For : isa(Brocken::AST::Node) {
        field $var    : param : reader = undef;    # Can be scalar or arrayref for multiple vars
        field $source : param : reader;
        field $body   : param : reader;
        field $is_my  : param : reader = 0;
    }

    class Brocken::AST::Stmt::Next : isa(Brocken::AST::Node) { }

    class Brocken::AST::Stmt::Last : isa(Brocken::AST::Node) { }

    class Brocken::AST::Stmt::Redo : isa(Brocken::AST::Node) { }

    class Brocken::AST::Stmt::Return : isa(Brocken::AST::Node) { field $expr : param : reader; }

    class Brocken::AST::Stmt::Exit : isa(Brocken::AST::Node) { field $expr : param : reader; }

    class Brocken::AST::Stmt::Map : isa(Brocken::AST::Node) { field $expr : param : reader; field $source : param : reader; }

    class Brocken::AST::Stmt::Defer : isa(Brocken::AST::Node) { field $block : param : reader; }

    class Brocken::AST::Stmt::Use : isa(Brocken::AST::Node) { field $package : param : reader; }

    class Brocken::AST::Stmt::Require : isa(Brocken::AST::Node) { field $package : param : reader; }

    class Brocken::AST::Stmt::Eval : isa(Brocken::AST::Node) { field $code : param : reader; }

    class Brocken::AST::Stmt::Yada : isa(Brocken::AST::Node) { }
}
1;
__END__

=pod

=head1 NAME

Brocken::AST::Stmt - Statement AST node classes

=head1 DESCRIPTION

Defines statement node types:

=over

=item Block - { ... } with statement list

=item VarDecl - my declarations

=item StateDecl - state declarations

=item Assignment - variable assignment

=item If - if/elsif/else

=item While - while loops

=item Return - return statements

=item Exit - exit statements

=item Map - map { ... } source

=item Defer - defer { ... }

=back

All classes inherit from Brocken::AST::Node.

=cut
1;
