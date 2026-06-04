package Brocken::TestHelpers;
use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Exporter 'import';
our @EXPORT_OK = qw(make_fake_funcs make_source_locs with_temp_file test_brocken);

sub test_brocken (%args) {
    my $source   = $args{source};
    my $name     = $args{name};
    my $expected = $args{expected};
    my $timeout  = $args{timeout} // 30;
    my $opts     = $args{opts}    // {};
    require Brocken::Compiler::Pipeline;
    require Brocken::Host;
    require Test2::V0;
    require File::Temp;
    my $os     = delete $opts->{os}   // delete $args{os}   // Brocken::Host::os();
    my $arch   = delete $opts->{arch} // delete $args{arch} // Brocken::Host::arch();
    my $suffix = $os eq 'win64' ? '.exe' : '';
    my ( $tmp_fh, $exe ) = File::Temp::tempfile( UNLINK => 1, SUFFIX => $suffix );
    close $tmp_fh;
    my $filename = delete $opts->{filename};
    my $parser   = delete $opts->{parser} // delete $args{parser} // 'pratt';
    my $p        = Brocken::Compiler::Pipeline->new( debug => 4, %$opts, parser => $parser, arch => $arch, os => $os );
    eval { $p->compile_source( $source, $exe, $filename ); };

    if ( my $err = $@ ) {
        Test2::V0::fail("$name - compilation failed: $err") if $name;
        return ( undef, "compilation: $err" );
    }
    if ( $os ne 'win64' ) {
        chmod 0755, $exe or die "Cannot chmod +x $exe: $!";
    }
    my $run = $exe;
    if ( $os ne 'win64' && $exe !~ m{^/} && $exe !~ m{^\./} ) {
        $run = './' . $exe;
    }
    my $output = _run_with_timeout( $run, $timeout );
    my $err = $@;
    if ($err) {
        Test2::V0::fail("$name - execution failed: $err") if $name;
        return ( undef, "execution: $err" );
    }
    chomp $output if defined $output;
    if ( ref $expected eq 'ARRAY' ) {
        my @out_lines = split /\n/, $output;
        Test2::V0::is( \@out_lines, $expected, $name );
    }
    elsif ( ref $expected eq 'Regexp' ) {
        Test2::V0::like( $output, $expected, $name );
    }
    elsif ( defined $expected ) {
        Test2::V0::is( $output, $expected, $name );
    }
    return ( $output, undef );
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

sub _run_with_timeout ( $run, $timeout = 30 ) {
    if ( $^O eq 'MSWin32' ) {
        require File::Temp;
        my ( $out_fh, $out_path ) = File::Temp::tempfile( UNLINK => 1, SUFFIX => '.out' );
        close $out_fh;
        my $pid = system( 1, qq{"$run" > "$out_path" 2>&1} );
        die "Cannot spawn $run: $!" if $pid < 0;
        my $elapsed = 0;
        while ( 1 ) {
            my $kid = waitpid( $pid, 1 );
            last if $kid == $pid;
            if ( $elapsed >= $timeout ) {
                `taskkill /F /T /PID $pid 2>NUL`;
                waitpid( $pid, 0 );
                die "TIMEOUT\n";
            }
            select( undef, undef, undef, 0.1 );
            $elapsed += 0.1;
        }
        open my $fh, '<:raw', $out_path or die "Cannot read $out_path: $!";
        local $/;
        my $out = <$fh>;
        close $fh;
        return $out;
    }
    else {
        my $output = eval {
            local $SIG{ALRM} = sub { die "TIMEOUT\n" };
            alarm($timeout);
            open my $fh, '-|', "$run 2>&1" or die "Cannot run $run: $!";
            local $/;
            my $out = <$fh>;
            close $fh;
            alarm(0);
            $out;
        };
        my $err = $@;
        alarm(0);
        die $err if $err;
        return $output;
    }
}
1;
