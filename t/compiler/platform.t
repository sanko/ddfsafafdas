use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
use Brocken::Target::OS;
subtest 'Platform base class' => sub {
    ok 1, 'Platform base loaded';
};
subtest 'Platform::Windows' => sub {
    require Brocken::Target::OS::Windows;
    my $p = Brocken::Target::OS::Windows->new( name => 'win64' );
    isa_ok $p, 'Brocken::Target::OS::Windows';
    isa_ok $p, 'Brocken::Target::OS';
    is $p->name,         'win64', 'Windows platform name';
    is $p->format_name,  'PE',    'Windows format_name is PE';
    is $p->shadow_space, 32,      'Windows x64 shadow space is 32';
};
subtest 'Platform::Linux' => sub {
    require Brocken::Target::OS::Linux;
    my $p = Brocken::Target::OS::Linux->new( name => 'linux' );
    isa_ok $p, 'Brocken::Target::OS::Linux';
    isa_ok $p, 'Brocken::Target::OS';
    is $p->name,         'linux', 'Linux platform name';
    is $p->format_name,  'ELF',   'Linux format_name is ELF';
    is $p->shadow_space, 0,       'Linux shadow space is 0';
};
done_testing;
