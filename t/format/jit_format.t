use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
require Brocken::Target::Format::JIT;
subtest 'JIT instantiation' => sub {
    my $f = Brocken::Target::Format::JIT->new;
    ok $f->isa('Brocken::Target::Format::JIT'), 'isa JIT';
    ok $f->isa('Brocken::Target::Format'),      'isa Format base';
};
subtest 'JIT import_rva after pre_layout' => sub {
    my $f = Brocken::Target::Format::JIT->new;
    $f->pre_layout( 4096, 512, 'x64', 'win64', 0 );
    my $rva = $f->import_rva('ExitProcess');
    ok defined $rva,                       'ExitProcess RVA defined';
    ok $rva > 0,                           'ExitProcess RVA positive';
    ok $f->import_rva('WriteFile') > 0,    'WriteFile has RVA';
    ok $f->import_rva('VirtualAlloc') > 0, 'VirtualAlloc has RVA';
    ok dies { $f->import_rva('Unknown') }, 'unknown import dies';
};
subtest 'JIT pre_layout sections' => sub {
    my $f = Brocken::Target::Format::JIT->new;
    $f->pre_layout( 4096, 512, 'x64', 'win64', 0 );
    my @names = map { $_->{name} } $f->layout->sections;
    is scalar(@names), 3,        'JIT has 3 sections';
    is $names[0],      '.text',  'first is .text';
    is $names[1],      '.data',  'second is .data';
    is $names[2],      '.idata', 'third is .idata';
};
subtest 'JIT write_bin returns empty string' => sub {
    my $f = Brocken::Target::Format::JIT->new;
    is $f->write_bin( 'test', "\x90", '', 'x64', 'win64', 'exe' ), '', 'JIT write_bin returns empty';
};
done_testing;
