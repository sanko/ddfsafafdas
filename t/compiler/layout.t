use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
require Brocken::Target::Format::Layout;
subtest 'basic layout' => sub {
    my $l = Brocken::Target::Format::Layout->new( file_align => 0x200, section_align => 0x1000 );
    $l->add_section( '.text', 4096, 5 );
    $l->add_section( '.data', 4096, 6 );
    my $total = $l->calculate(0x1000);
    ok $total > 0, 'total image size positive';
    is $l->get('.text')->{rva}, 0x1000, '.text RVA = 0x1000';
    is $l->get('.data')->{rva}, 0x2000, '.data RVA = 0x2000';
    ok $l->get('.text')->{off} >= 0x1000, '.text file offset >= header';
};
subtest 'many sections' => sub {
    my $l = Brocken::Target::Format::Layout->new( file_align => 0x200, section_align => 0x1000 );
    for my $i ( 1 .. 8 ) {
        $l->add_section( ".sec_$i", 4096, 0 );
    }
    $l->calculate(0x1000);
    for my $i ( 1 .. 8 ) {
        is $l->get(".sec_$i")->{rva}, $i * 0x1000, ".sec_$i RVA = $i * 0x1000";
    }
};
subtest 'variable section sizes' => sub {
    my $l = Brocken::Target::Format::Layout->new( file_align => 0x200, section_align => 0x1000 );
    $l->add_section( '.text',  4096, 5 );
    $l->add_section( '.data',  2048, 6 );
    $l->add_section( '.small', 50,   0 );
    $l->calculate(0x1000);
    is $l->get('.text')->{size},  4096,   '.text size';
    is $l->get('.data')->{size},  2048,   '.data size';
    is $l->get('.small')->{size}, 50,     '.small size';
    is $l->get('.text')->{rva},   0x1000, '.text RVA';
    is $l->get('.data')->{rva},   0x2000, '.data RVA';
    is $l->get('.small')->{rva},  0x3000, '.small RVA';
};
subtest 'file offsets respect file alignment' => sub {
    my $l = Brocken::Target::Format::Layout->new( file_align => 0x200, section_align => 0x1000 );
    $l->add_section( '.text', 100, 5 );
    $l->calculate(0x1000);
    ok $l->get('.text')->{off} % 0x200 == 0, '.text offset aligned to 0x200';
};
subtest 'get dies on missing section' => sub {
    my $l = Brocken::Target::Format::Layout->new( file_align => 0x200, section_align => 0x1000 );
    $l->add_section( '.text', 4096, 5 );
    ok dies { $l->get('.nope') }, 'dies for unknown section';
};
done_testing;

