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
    my $expected = $args{expected};
    my $timeout  = $args{timeout} // 30;
    require Brocken;
    require Test2::V0;
    require File::Temp;
    my ( $tmp_fh, $exe ) = File::Temp::tempfile( UNLINK => 1, SUFFIX => '.exe' );
    close $tmp_fh;
    my $p = Brocken::Compiler->new( debug => 4 );
    eval { $p->compile_source( $source, $exe ); };

    if ( my $err = $@ ) {
        Test2::V0::fail("$name - compilation failed: $err");
        return;
    }
    my $run    = ( $^O eq 'MSWin32' ? '' : './' ) . $exe;
    my $output = eval {
        local $SIG{ALRM} = sub { die "TIMEOUT\n" };
        alarm($timeout);
        system( q[gdb -batch -ex "run" -ex "bt" -ex "x/i $pc" -ex "info registers" -ex "disas" ] . $run );
        open my $fh, '-|', "$run 2>&1" or die "Cannot run $run: $!";
        local $/;
        my $out = <$fh>;
        close $fh;
        alarm(0);
        $out;
    };
    my $err = $@;
    alarm(0);
    if ($err) {
        Test2::V0::fail("$name - execution failed: $err");
        return;
    }
    chomp $output if defined $output;
    if ( ref $expected eq 'ARRAY' ) {
        my @out_lines = split /\n/, $output;
        my $ok        = ( @out_lines == @$expected );
        if ($ok) {
            for my $i ( 0 .. $#$expected ) {
                $ok = 0 unless defined $out_lines[$i] && $out_lines[$i] eq $expected->[$i];
            }
        }
        Test2::V0::ok( $ok, $name ) or Test2::V0::diag( 'Expected: ' . join( ', ', @$expected ) . ' Got: ' . join( ', ', @out_lines ) );
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
