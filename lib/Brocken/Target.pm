package Brocken::Target {
    use v5.40;
    use feature 'class';
    no warnings 'experimental::class';
    class Brocken::Target {
        field $os : param : reader;
        field $arch : param : reader;
        method registers() { die "Abstract" }
        method emit_op($as, $inst, $reg_map, $driver) { die "Abstract" }
        method compile_intrinsic($as, $inst, $reg_map, $driver) { die "Abstract" }
        method val($reg_map, $arg) {
            return undef unless defined $arg;
            return $reg_map->{$arg} if !ref($arg) && $arg =~ /^%/;
            return $arg;
        }
    }
}

1;
