package Brocken::Platform {
    use v5.40;
    use feature 'class';
    no warnings 'experimental::class';

    class Brocken::Platform {
        field $os : param : reader;
        method format_name()                                            {...}
        method shadow_space()                                           {0}
        method emit_intrinsic( $target, $as, $inst, $reg_map, $driver ) {...}
    }
}
1;
