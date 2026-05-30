use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';

sub build_ir {
    my ($source) = @_;
    require Brocken::Core::Lexer;
    require Brocken::Core::Parser;
    require Brocken::Compiler::Pipeline;
    require Brocken::Compiler::DataSegment;
    require Brocken::Compiler::Lowering;
    my $tokens   = Brocken::Core::Lexer->new( source => $source )->lex();
    my $ast      = Brocken::Core::Parser->new( tokens => $tokens )->parse();
    my $driver   = Brocken::Compiler::Pipeline->new( arch => 'x64' );
    my $ds       = Brocken::Compiler::DataSegment->new();
    my $lowering = Brocken::Compiler::Lowering->new( data_segment => $ds, driver => $driver );
    $lowering->lower_program($ast);
    return $lowering->builder;
}
subtest 'Coverage: simple say 42' => sub {
    require Brocken::Compiler::Optimizer;
    my $builder = build_ir('say 42;');
    my $opt     = Brocken::Compiler::Optimizer->new();
    my $before  = $opt->coverage_report($builder);
    ok $before->{total_insts} > 0, 'pre-opt: has instructions';
    ok $before->{reachable} > 0,   'pre-opt: has reachable instructions';
    $opt->optimize($builder);
    my $after = $opt->coverage_report($builder);
    ok $after->{total_insts} <= $before->{total_insts}, 'post-opt: total <= pre-opt';
    ok $after->{reachable} > 0,                         'post-opt: reachable > 0';
    diag "say 42: $after->{total_insts} total, $after->{reachable} reachable, $after->{unreachable} unreachable";
};
subtest 'Coverage: unused variable eliminated by DCE' => sub {
    require Brocken::Compiler::Optimizer;
    my $builder = build_ir('my Int $x = 42; my Int $y = $x + 1; say $y;');
    my $opt     = Brocken::Compiler::Optimizer->new();
    my $before  = $opt->coverage_report($builder);
    $opt->optimize($builder);
    my $after = $opt->coverage_report($builder);
    ok $after->{total_insts} < $before->{total_insts}, 'unused variable: DCE reduced instruction count';
    diag "unused var: $before->{total_insts} -> $after->{total_insts} instructions";
};
subtest 'Coverage: dead constant eliminated' => sub {
    require Brocken::Compiler::Optimizer;
    my $builder = build_ir('my Int $x = 99; my Int $y = 42; say $y;');
    my $opt     = Brocken::Compiler::Optimizer->new();
    my $before  = $opt->coverage_report($builder);
    $opt->optimize($builder);
    my $after = $opt->coverage_report($builder);
    ok $after->{total_insts} < $before->{total_insts}, 'dead constant: DCE reduced count';
    diag "dead const: $before->{total_insts} -> $after->{total_insts}";
};
subtest 'Coverage: conditional branch reachability' => sub {
    require Brocken::Compiler::Optimizer;
    my $builder = build_ir('my Int $x = 42; if ($x == 42) { say "yes" } else { say "no" };');
    my $opt     = Brocken::Compiler::Optimizer->new();
    my $report  = $opt->coverage_report($builder);
    ok $report->{reachable} > 0,    'conditional: reachable > 0';
    ok $report->{unreachable} >= 0, 'conditional: unreachable >= 0';
    my $reach_ops = $report->{opcode_reach};
    ok $reach_ops->{cond_br}, 'conditional: cond_br is reachable';
    diag "if/else: $report->{total_insts} total, $report->{reachable} reachable";
};
subtest 'Coverage: while loop reachability' => sub {
    require Brocken::Compiler::Optimizer;
    my $builder = build_ir('my Int $i = 0; while ($i < 3) { say $i; $i = $i + 1; };');
    my $opt     = Brocken::Compiler::Optimizer->new();
    my $report  = $opt->coverage_report($builder);
    ok $report->{reachable} > 0, 'while: reachable > 0';
    my $total = $report->{opcode_total};
    ok $total->{jmp}, 'while: has jmp instruction';
    diag "while loop: $report->{total_insts} total, $report->{reachable} reachable";
};
subtest 'Coverage: post-optimization coverage rate' => sub {
    require Brocken::Compiler::Optimizer;
    my $builder = build_ir('my Int $x = 99; my Int $y = 42; say 40 + 2;');
    my $opt     = Brocken::Compiler::Optimizer->new();
    $opt->optimize($builder);
    my $report = $opt->coverage_report($builder);
    my $pct    = $report->{total_insts} > 0 ? sprintf( '%.1f', $report->{reachable} / $report->{total_insts} * 100 ) : 'N/A';
    diag "Coverage rate: $pct% ($report->{reachable}/$report->{total_insts})";
    ok 1, 'coverage rate computed';
};
done_testing;
