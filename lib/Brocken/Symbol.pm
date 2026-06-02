package Brocken::Symbol {
    use v5.40;
    use utf8;
    use feature 'class';
    no warnings 'portable', 'experimental::class';

    class Brocken::Symbol {
        field $name           : param : reader;
        field $type           : param : reader;
        field $is_state       : param : reader = 0;
        field $state_idx      : param : reader = undef;
        field $stack_offset   : param : reader = undef;
        field $shadow_offset  : param : reader = undef;
        field $isolate_offset : param : reader = undef;
    }
}
1;
