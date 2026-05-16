use v5.40;
use Test::More;
use FFI::ExtractSymbols;

my $dll = 'brocken_out.dll';
ok(-f $dll, "brocken_out.dll generated");

my @exports;
FFI::ExtractSymbols::extract_symbols($dll, export => sub { push @exports, $_[0] });

ok(grep { $_ eq 'add' } @exports, "Exported 'add' found in brocken_out.dll");

done_testing();
