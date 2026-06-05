use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
require Brocken::Target::OS::macOS;
subtest 'Darwin platform instantiation' => sub {
    my $p = Brocken::Target::OS::macOS->new( name => 'macos' );
    ok $p->isa('Brocken::Target::OS::macOS'), 'isa Darwin';
    ok $p->isa('Brocken::Target::OS'),        'isa Platform base';
};
subtest 'Darwin format_name' => sub {
    my $p = Brocken::Target::OS::macOS->new( name => 'macos' );
    is $p->format_name, 'MachO', 'Darwin format is MachO';
};
subtest 'Darwin shadow_space' => sub {
    my $p = Brocken::Target::OS::macOS->new( name => 'macos' );
    is $p->shadow_space, 0, 'Darwin shadow_space = 0 (inherited default)';
};
done_testing;
