package Pulse {
    use v5.40;
    use Pulse::Emit;
    use Pulse::Format;
    use Pulse::Compiler;

    package Pulse::Util {
        sub align ( $val, $align ) { ( $val + $align - 1 ) & ~( $align - 1 ) }
    }
};
1;
