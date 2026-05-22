use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
use Brocken::Platform;
subtest 'Platform base class' => sub {
    ok 1, 'Platform base loaded';
};
subtest 'Platform::Windows' => sub {
    require Brocken::Platform::Windows;
    my $p = Brocken::Platform::Windows->new( os => 'win64' );
    isa_ok $p, 'Brocken::Platform::Windows';
    isa_ok $p, 'Brocken::Platform';
    is $p->os,           'win64', 'Windows platform os';
    is $p->format_name,  'PE',    'Windows format_name is PE';
    is $p->shadow_space, 32,      'Windows x64 shadow space is 32';
};
subtest 'Platform::Linux' => sub {
    require Brocken::Platform::Linux;
    my $p = Brocken::Platform::Linux->new( os => 'linux' );
    isa_ok $p, 'Brocken::Platform::Linux';
    isa_ok $p, 'Brocken::Platform';
    is $p->os,           'linux', 'Linux platform os';
    is $p->format_name,  'ELF',   'Linux format_name is ELF';
    is $p->shadow_space, 0,       'Linux x64 shadow space is 0';
};
done_testing;
