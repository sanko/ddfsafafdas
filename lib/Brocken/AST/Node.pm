package Brocken::AST::Node {
    use v5.40;
    use feature 'class';
    no warnings 'experimental::class';
    #
    class Brocken::AST::Node {
        field $line : param : reader = 0;
        field $col  : param : reader = 0;
        method dump { ( ref $self ) =~ s/.*:://r }
    }
}
1;
