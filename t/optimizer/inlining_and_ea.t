use v5.40;
use lib 'lib';
use Brocken::TestHelpers qw(test_brocken);
use Test2::V0;
test_brocken(
    name   => 'Method Inlining and Stack Promotion via Escape Analysis',
    source => q{
        class Point {
            field Any $x;
            field Any $y;
            method init(Int $a, Int $b) { $x = $a; $y = $b; }
            method get_x() { return $x; }
        }

        # Point->new is compiled.
        # $p->init(100, 200) is statically resolved to Point::init and INLINED.
        # $p->get_x() is statically resolved to Point::get_x and INLINED.
        #
        # Because all method boundaries disappear, Escape Analysis detects that
        # the Point instance ($p) never escapes this frame!
        # The entire Point object is promoted and allocated directly on the physical stack!
        my Point $p = Point->new();
        $p->init(100, 200);
        say "X coordinate: " . $p->get_x();
    },
    expected => ["X coordinate: 100"]
);
done_testing;

