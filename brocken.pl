#!/usr/bin/env perl
use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use lib 'lib';
use Brocken;
$|++;

my $source_code = <<'BROCKEN';
class User {
    field $id;
    field $status;

    method set_id(Int $val) {
        $id = $val;
        $status = 1;
    }

    method get_id() {
        return $id;
    }
}

say "Booting Brocken Runtime... ❤️😭";

# Milestone 8: Test Native OOP & Static Dispatch
my Any $u = User->new();
$u->set_id(42);

say "Brocken executed successfully!";
exit $u->get_id();
BROCKEN

say "Bootstrapping Brocken...";
my $p = Brocken::Compiler->new();
say "Targeting OS: " . $p->os . " | Arch: " . $p->arch;

my $tokens = Brocken::Lexer->new( source => $source_code )->lex();
my $ast    = Brocken::Parser->new( tokens => $tokens )->parse();
my $ds     = Brocken::Compiler::DataSegment->new();

my $lowering = Brocken::Compiler::Lowering->new( data_segment => $ds, driver => $p );
$lowering->lower_program($ast);

my $optimizer = Brocken::Compiler::Optimizer->new();
$optimizer->optimize( $lowering->builder );

$lowering->builder->dump_ir("FINAL IR");

my $est_text = scalar($lowering->builder->instructions) * 32 + 4096;
my $est_data = length($ds->get_raw_data()) + 4096;
$p->format->pre_layout($est_text, $est_data, $p->arch, $p->os);

my $codegen = Brocken::Codegen->new( arch => $p->arch );
$codegen->compile([ $lowering->builder->instructions() ], $p );
$p->as->resolve();

my $ext = $p->os eq 'win64' ? '.exe' : '';
my $exe = $p->format->write_bin( "brocken_out$ext", $p->as->code, $ds->get_raw_data(), $p->arch, $p->os );

say "Executing Native Binary...";
my $run = $^O eq 'MSWin32' ? $exe : "./$exe";
system($run);
say "Exit code: " . ( $? >> 8 );
