package Brocken::TestHelpers;
use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Exporter 'import';
our @EXPORT_OK = qw(make_fake_funcs make_source_locs with_temp_file test_brocken);

sub test_brocken {
    my %args     = @_;
    my $name     = $args{name};
    my $source   = $args{source};
    my $expected = $args{expected};        # Arrayref of lines or regex
    my $timeout  = $args{timeout} // 30;
    require Brocken;
    require Test2::V0;
    my $lexer    = Brocken::Lexer->new( source => $source );
    my $tokens   = $lexer->lex();
    my $parser   = Brocken::Parser->new( tokens => $tokens );
    my $ast      = $parser->parse();
    my $ds       = Brocken::Compiler::DataSegment->new();
    my $driver   = Brocken::Compiler->new();
    my $lowering = Brocken::Compiler::Lowering->new( data_segment => $ds, driver => $driver );
    $lowering->lower_program($ast);
    my $optimizer = Brocken::Compiler::Optimizer->new();
    $optimizer->optimize( $lowering->builder );
    my $p = Brocken::Compiler->new();
    warn;
    $p->format->pre_layout( scalar( $lowering->builder->instructions ) * 32 + 8192, length( $ds->get_raw_data() ) + 8192, $p->arch, $p->os, 0 );
    warn;
    my $codegen = Brocken::Codegen->new( arch => $p->arch );
    warn;
    $codegen->compile( [ $lowering->builder->instructions() ], $p );
    warn;
    $p->as->resolve();
    warn;
    my $ext = $p->os eq 'win64' ? '.exe' : '';

my $exe = "test_bin$ext";

    $p->compile_source($source, $exe);
    warn;
    my $run = ( $^O eq 'MSWin32' ? '' : './' ) . $exe;
    warn;
    my $output = eval {
        local $SIG{ALRM} = sub { die "TIMEOUT\n" };
        warn;
        alarm($timeout);
        warn $run;

        #~ my $out = `$run 2>&1`;
        my $out = system $run;
        warn;
        warn $out;
        alarm(0);
        $out;
    };
    warn;
    my $err = $@;
    alarm(0);
    warn;
    unlink $exe if -e $exe;
    warn;
    if ($err) {
        warn;
        Test2::V0::fail("$name - $err");
        return;
    }
    warn;
    if ( ref $expected eq 'ARRAY' ) {
        my @out_lines = split /\n/, $output;

        # Clean up output lines (remove debug etc if any)
        @out_lines = grep { !/^Debug:|^Executing/ } @out_lines;
        Test2::V0::is_deeply( \@out_lines, $expected, $name );
    }
    elsif ( ref $expected eq 'Regexp' ) {
        Test2::V0::like( $output, $expected, $name );
    }
    else {
        Test2::V0::pass($name);
    }
}

sub make_fake_funcs {
    return [
        { name => 'func_a', start => 0, end => 96, ctx_size => 64, params => [], locals => [] },
        {   name     => 'func_b',
            start    => 256,
            end      => 384,
            ctx_size => 64,
            params   => [ { name => '$x', type => 'Int', slot => 16 } ],
            locals   => [ { name => '$y', type => 'Int', slot => 24 } ]
        },
        { name => 'func_c', start => 512, end => 640, ctx_size => 48, params => [], locals => [] },
    ];
}

sub make_source_locs {
    return [ { offset => 0, line => 1, col => 1 }, { offset => 64, line => 5, col => 8 }, { offset => 128, line => 10, col => 4 }, ];
}

sub with_temp_file {
    my ( $code, $suffix ) = @_;
    require File::Temp;
    my $file = File::Temp->new( UNLINK => 1, SUFFIX => $suffix // '.bin' );
    $code->( $file->filename );
}
1;
