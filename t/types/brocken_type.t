use v5.40;
use feature 'class';
no warnings 'experimental::class';
use Test2::V0;
use lib 'lib';
use Brocken::Core::Type;
subtest 'Primitive types' => sub {
    for my $name (qw(void bool char uchar short ushort int uint long ulong longlong ulonglong)) {
        my $t = Brocken::Core::Type->new($name);
        ok $t->isa('Brocken::Core::Type'), "type $name isa Type";
        is $t->{name}, $name, "type name $name";
        ok $t->{size} >= 0, "size >= 0 for $name";
    }
};
subtest 'Fixed-width integer types' => sub {
    my $t8 = Brocken::Core::Type->new('int8');
    is $t8->{size}, 1, 'int8 size=1';
    my $t16 = Brocken::Core::Type->new('uint16');
    is $t16->{size}, 2, 'uint16 size=2';
    my $t32 = Brocken::Core::Type->new('int32');
    is $t32->{size}, 4, 'int32 size=4';
    my $t64 = Brocken::Core::Type->new('uint64');
    is $t64->{size}, 8, 'uint64 size=8';
    ok $t64->{unsigned}, 'uint64 is unsigned';
};
subtest 'Floating point types' => sub {
    my $f = Brocken::Core::Type->new('float');
    ok $f->{is_float}, 'float is_float';
    is $f->{size}, 4, 'float size=4';
    my $d = Brocken::Core::Type->new('double');
    ok $d->{is_float}, 'double is_float';
    is $d->{size}, 8, 'double size=8';
};
subtest 'Brocken native types' => sub {
    my $int = Brocken::Core::Type->new('Int');
    is $int->{size}, 8, 'Int size=8';
    my $any = Brocken::Core::Type->new('Any');
    is $any->{size}, 16, 'Any size=16';
    my $str = Brocken::Core::Type->new('String');
    ok $str->{is_pointer}, 'String is_pointer';
    my $bool = Brocken::Core::Type->new('Bool');
    is $bool->{size}, 8, 'Bool size=8';
    my $arr = Brocken::Core::Type->new('Array');
    is $arr->{size}, 8, 'Array size=8';
};
subtest 'Unknown type defaults' => sub {
    my $t = Brocken::Core::Type->new('NonExistentType');
    is $t->{size}, 8,                 'unknown type defaults to 8 bytes';
    is $t->{name}, 'NonExistentType', 'name preserved';
};
subtest 'Pointer' => sub {
    my $int_t = Brocken::Core::Type->new('Int');
    my $ptr   = Brocken::Core::Type::Pointer($int_t);
    is $ptr->{size}, 8, 'pointer size=8';
    ok $ptr->{is_pointer}, 'is_pointer flag';
    is $ptr->{name},         '*Int', 'pointer name';
    is $ptr->{element_type}, $int_t, 'element type preserved';
};
subtest 'Array' => sub {
    my $int_t = Brocken::Core::Type->new('Int');
    my $arr   = Brocken::Core::Type::Array( $int_t, 5 );
    is $arr->{size}, 40, '5*8=40 array size';
    ok $arr->{is_array}, 'is_array flag';
    is $arr->{array_count}, 5,         'count=5';
    is $arr->{name},        '[5:Int]', 'array name';
};
subtest 'Struct' => sub {
    my $int_t  = Brocken::Core::Type->new('Int');
    my $char_t = Brocken::Core::Type->new('char');
    my $s      = Brocken::Core::Type::Struct( 'MyStruct', [ { name => 'x', type => $int_t }, { name => 'c', type => $char_t }, ] );
    ok $s->{is_struct}, 'is_struct flag';
    is $s->{name},                  'MyStruct', 'struct name';
    is scalar( @{ $s->{fields} } ), 2,          'two fields';
    ok $s->{size} > 0, 'struct has positive size';
};
subtest 'Union' => sub {
    my $int_t  = Brocken::Core::Type->new('Int');
    my $char_t = Brocken::Core::Type->new('char');
    my $u      = Brocken::Core::Type::Union( [ { name => 'i', type => $int_t }, { name => 'c', type => $char_t }, ] );
    ok $u->{is_union}, 'is_union flag';
    is $u->{size},                    8, 'union size = max(8,1) = 8';
    is scalar( @{ $u->{variants} } ), 2, 'two variants';
};
subtest 'Callback' => sub {
    my $int_t  = Brocken::Core::Type->new('Int');
    my $void_t = Brocken::Core::Type->new('void');
    my $cb     = Brocken::Core::Type::Callback( $int_t, [ $int_t, $void_t ] );
    ok $cb->{is_pointer}, 'callback is_pointer';
    is $cb->{size},              8,     'callback size=8';
    is $cb->{return_type}{name}, 'Int', 'return type Int';
};
subtest 'Enum' => sub {
    my $int_t = Brocken::Core::Type->new('Int');
    my $e     = Brocken::Core::Type::Enum( $int_t, { A => 1, B => 2 } );
    ok $e->{is_enum}, 'is_enum flag';
    is $e->{size}, 8, 'enum size matches base type';
};
subtest 'Predicates' => sub {
    my $int_t  = Brocken::Core::Type->new('Int');
    my $ptr    = Brocken::Core::Type::Pointer($int_t);
    my $float  = Brocken::Core::Type->new('float');
    my $uint_t = Brocken::Core::Type->new('uint32');
    my $void_t = Brocken::Core::Type->new('void');
    ok $int_t->is_numeric,   'Int is_numeric';
    ok $int_t->is_integer,   'Int is_integer';
    ok $int_t->is_signed,    'Int is_signed';
    ok !$ptr->is_numeric,    'pointer not numeric';
    ok $float->is_numeric,   'float is_numeric';
    ok !$float->is_integer,  'float not integer';
    ok !$uint_t->is_signed,  'uint32 not signed';
    ok !$void_t->is_numeric, 'void not numeric';
};
done_testing;

