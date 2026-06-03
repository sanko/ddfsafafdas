use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
use Brocken::Target::Format;
subtest 'Format base class' => sub {
    my $f = Brocken::Target::Format->new( type => 'exe' );
    ok $f->isa('Brocken::Target::Format'), 'format isa Format';
    is $f->type, 'exe', 'type is exe';
};
subtest 'Format debug data storage' => sub {
    my $f = Brocken::Target::Format->new( type => 'exe' );
    $f->set_debug_data( { '.debug_line' => 'line_data', '.debug_info' => 'info_data' } );
    is $f->debug_section('.debug_line'), 'line_data', 'debug section stored';
    is $f->debug_section('.debug_info'), 'info_data', 'debug info section stored';
    ok !defined( $f->debug_section('.nonexistent') ) || $f->debug_section('.nonexistent') eq '', 'nonexistent section returns falsy';
};
subtest 'Format set_func_ranges and set_labels' => sub {
    my $f = Brocken::Target::Format->new( type => 'exe' );
    $f->set_func_ranges( [ { name => 'main', start => 0, end => 128 } ] );
    is scalar( @{ $f->func_ranges } ), 1, 'func_ranges set';
    $f->set_labels( { 'L_main' => 0, 'L_end' => 128 } );
    is $f->labels->{'L_main'}, 0, 'label set';
};
subtest 'Format set_exported_funcs' => sub {
    my $f = Brocken::Target::Format->new( type => 'shared' );
    $f->set_exported_funcs( [ 'add', 'sub' ] );
    is scalar( @{ $f->exported_funcs } ), 2,     'exports count';
    is $f->exported_funcs->[0],           'add', 'first export is add';
};
done_testing;
