package Brocken::TestHelpers;
use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Exporter 'import';
our @EXPORT_OK = qw(make_fake_funcs make_source_locs with_temp_file);

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
