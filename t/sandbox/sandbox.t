use v5.40;
use utf8;
use Test2::V0;
use lib 'lib';
subtest 'Sandbox memory limit' => sub {
    eval { require Sandbox; 1 } or skip_all "Sandbox module not available";
    my $sb = Sandbox->new();
    $sb->limit_memory(1024);
    $sb->eval('my $a = "x"; while(1) { $a = $a . $a; }');
    ok $sb->error,         'memory limit triggered error';
    ok $sb->error_message, 'error message present';
};
subtest 'Sandbox fuel limit' => sub {
    eval { require Sandbox; 1 } or skip_all "Sandbox module not available";
    my $sb = Sandbox->new();
    $sb->limit_fuel(10);
    $sb->eval('while(1) {}');
    ok $sb->error,         'fuel limit triggered error';
    ok $sb->error_message, 'error message present';
};
subtest 'Sandbox capability restriction' => sub {
    eval { require Sandbox; 1 } or skip_all "Sandbox module not available";
    my $sb = Sandbox->new();
    $sb->allow(0);
    $sb->eval("open('test.txt', 'r');");
    ok $sb->error,         'capability restriction triggered error';
    ok $sb->error_message, 'error message present';
};
done_testing;
