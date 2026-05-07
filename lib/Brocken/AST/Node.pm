package Brocken::AST::Node {
    use v5.40;
    use feature 'class';
    no warnings 'experimental::class';
    #
    class Brocken::AST::Node {
        method dump { ( ref $self ) =~ s/.*:://r }
    }
}
1;
