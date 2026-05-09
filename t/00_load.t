use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';
ok my $fmt_pkg = 'Brocken::Format',            'Format base class loaded';
ok require Brocken::Format,                    'require Format.pm';
ok my $layout_pkg = 'Brocken::Format::Layout', 'Layout class';
ok require Brocken::Format::Layout,            'require Layout.pm';
subtest 'DWARF' => sub {
    ok require Brocken::Format::DWARF, 'require DWARF.pm';
};
subtest 'PE' => sub {
    ok require Brocken::Format::PE, 'require PE.pm';
};
subtest 'ELF' => sub {
    ok require Brocken::Format::ELF, 'require ELF.pm';
};
subtest 'Platform' => sub {
    ok require Brocken::Platform,          'require Platform.pm';
    ok require Brocken::Platform::Windows, 'require Platform/Windows.pm';
    ok require Brocken::Platform::Linux,   'require Platform/Linux.pm';
};
subtest 'Compiler' => sub {
    ok require Brocken::Compiler, 'require Compiler.pm';
};
done_testing;
