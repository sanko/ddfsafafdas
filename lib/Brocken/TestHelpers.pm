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
    $p->format->pre_layout( scalar( $lowering->builder->instructions ) * 32 + 8192, length( $ds->get_raw_data() ) + 8192, $p->arch, $p->os, 0 );
    my $codegen = Brocken::Codegen->new( arch => $p->arch );
    $codegen->compile( [ $lowering->builder->instructions() ], $p );
    $p->as->resolve();
    my $ext    = $p->os eq 'win64' ? '.exe' : '';
    my $exe    = $p->format->write_bin( "test_bin$ext", $p->as->code, $ds->get_raw_data(), $p->arch, $p->os );
    my $run    = ( $^O eq 'MSWin32' ? '' : './' ) . $exe;
    my $output = eval {
        local $SIG{ALRM} = sub { die "TIMEOUT\n" };
        alarm($timeout);
        my $out = `$run 2>&1`;
        alarm(0);
        $out;
    };
    my $err = $@;
    alarm(0);
    unlink $exe if -e $exe;
    if ($err) {
        Test::More::fail("$name - $err");
        return;
    }
    if ( ref $expected eq 'ARRAY' ) {
        my @out_lines = split /\n/, $output;

        # Clean up output lines (remove debug etc if any)
        @out_lines = grep { !/^Debug:|^Executing/ } @out_lines;
        Test::More::is_deeply( \@out_lines, $expected, $name );
    }
    elsif ( ref $expected eq 'Regexp' ) {
        Test::More::like( $output, $expected, $name );
    }
    else {
        Test::More::pass($name);
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
