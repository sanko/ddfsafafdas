on configure => sub {
    requires 'Module::Build::Tiny', '0.034';
    requires 'Path::Tiny';
    requires 'perl', 'v5.40.0';
};
on test => sub {
    requires 'Affix';
};
