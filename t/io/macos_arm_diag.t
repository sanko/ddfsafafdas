use v5.40;
use utf8;
use feature 'class';
no warnings 'portable', 'experimental::class';
use Test2::V0;
use lib 'lib';

my $diag = sub ($msg) { diag $msg };

$diag->("=== Brocken macOS ARM64 Diagnostics ===");

my $uname_s = `uname -s`;
my $uname_m = `uname -m`;
chomp $uname_s;
chomp $uname_m;
$diag->("uname -s: $uname_s");
$diag->("uname -m: $uname_m");

my $is_macos_arm = ( $uname_s eq 'Darwin' && $uname_m eq 'arm64' );

if ( !$is_macos_arm ) {
    $diag->("Not macOS ARM64, skipping diagnostics");
    done_testing;
    exit 0;
}

my $host_require_ok = eval { require Brocken::Host; 1 };
$diag->("Brocken::Host loaded: " . ( $host_require_ok ? 'yes' : "NO - $@" ));

my $host_os   = $host_require_ok ? eval { Brocken::Host::os() }   : undef;
my $host_arch = $host_require_ok ? eval { Brocken::Host::arch() } : undef;
$diag->("Brocken::Host::os:   " . ( $host_os   // "ERROR: $@" ));
$diag->("Brocken::Host::arch: " . ( $host_arch // "ERROR: $@" ));

$diag->("BROCKEN_ARCH env: " . ( $ENV{BROCKEN_ARCH} // '(unset)' ) );
$diag->("PROCESSOR_ARCHITECTURE: " . ( $ENV{PROCESSOR_ARCHITECTURE} // '(unset)' ) );

# Step 1: Try to compile say 42
$diag->("--- Step 1: Compile 'say 42' ---");

my $require_ok = eval { require Brocken::Compiler::Pipeline; 1 };
if ( !$require_ok ) {
    $diag->("Cannot load Brocken::Compiler::Pipeline: $@");
    done_testing;
    exit 0;
}

require File::Temp;

my $exe;
my $p;
{
    my ( $tmp_fh, $tmp_exe ) = File::Temp::tempfile( UNLINK => 0 );
    close $tmp_fh;
    $exe = $tmp_exe;
}

$p = Brocken::Compiler::Pipeline->new(
    debug => 4, parser => 'pratt', arch => $host_arch, os => $host_os
);

my $compile_ok = eval { $p->compile_source( 'say 42;', $exe, undef ); 1 };
my $compile_err = $@;
if ( $compile_err ) { chomp $compile_err }

if ( !$compile_ok ) {
    $diag->("Compilation FAILED: $compile_err");
    $diag->("Skipping remaining binary diagnostics");
    chmod 0755, $exe;
    unlink $exe if -e $exe;
    done_testing;
    exit 0;
}

$diag->("Compilation OK");
$diag->("Binary path: $exe");

my $exists = -e $exe;
my $size   = $exists ? -s $exe : 0;
$diag->("Binary exists: $exists, size: $size bytes");

# Step 2: Dump binary header
$diag->("--- Step 2: Binary header dump ---");

if ($exists && $size > 0) {
    my $fh;
    if ( open $fh, '<:raw', $exe ) {
        my $header;
        my $bytes_read = read $fh, $header, 64;
        $diag->("Read $bytes_read bytes from start");

        my $magic = unpack('H*', substr($header, 0, 4));
        $diag->("Magic: 0x$magic");

        if ( $bytes_read >= 32 ) {
            my @words = unpack('L<8', substr($header, 0, 32));
            $diag->("cputype: " . ($words[1]));
            $diag->("cpusubtype: " . ($words[2]));
            $diag->("filetype: " . ($words[3]));
            $diag->("ncmds: " . ($words[4]));
            $diag->("sizeofcmds: " . ($words[5]));
            $diag->("flags: 0x" . sprintf('%x', $words[6]));
            $diag->("reserved: " . ($words[7]));
        }

        close $fh;
    }
    else {
        $diag->("Cannot open binary: $!");
    }
}

# Step 3: Dump load commands
$diag->("--- Step 3: Load commands ---");

if ($exists && $size > 0) {
    my $fh;
    if ( open $fh, '<:raw', $exe ) {
        my $header;
        read $fh, $header, 32;
    my @words = unpack('L<8', $header);
    my $ncmds      = $words[4];
    my $sizeofcmds = $words[5];

    my $offset = 32;
    for my $i ( 0 .. $ncmds - 1 ) {
        last if $offset + 8 > $size;
        seek $fh, $offset, 0;
        my $cmd_header;
        read $fh, $cmd_header, 8;
        my ( $cmd, $cmdsize ) = unpack('L<2', $cmd_header);
        my $cmd_name = do {
            if    ( $cmd == 0x19 )       { 'LC_SEGMENT_64' }
            elsif ( $cmd == 0x80000028 ) { 'LC_MAIN' }
            elsif ( $cmd == 0xE )        { 'LC_DYLD_INFO_ONLY' }
            elsif ( $cmd == 0xC )        { 'LC_LOAD_DYLIB' }
            elsif ( $cmd == 0x80000022 ) { 'LC_DYLD_INFO' }
            elsif ( $cmd == 0x2 )        { 'LC_SYMTAB' }
            elsif ( $cmd == 0xB )        { 'LC_DYSYMTAB' }
            elsif ( $cmd == 0xD )        { 'LC_ID_DYLIB' }
            else                         { sprintf('0x%x', $cmd) }
        };
        $diag->("  LC[$i]: cmd=$cmd_name, size=$cmdsize (offset=0x" . sprintf('%x', $offset) . ")");
        $offset += $cmdsize;
    }
    close $fh;
    }
}

# Step 4: Binary file info
$diag->("--- Step 4: Binary file info ---");

my $file_info = `file "$exe" 2>&1`;
chomp $file_info if $file_info;
$diag->("file: $file_info");

my $otool_info = `otool -h "$exe" 2>&1`;
chomp $otool_info if $otool_info;
$diag->("otool -h: $otool_info");

my $otool_lc = `otool -l "$exe" 2>&1`;
if ($otool_lc) {
    my @lines = split /\n/, $otool_lc;
    for my $i ( 0 .. $#lines ) {
        last if $i > 20;
        $diag->("  otool: $lines[$i]");
    }
    if ( $#lines > 20 ) {
        $diag->("  ... (" . ( $#lines - 20 ) . " more lines)");
    }
}

# Step 5: Code signing
$diag->("--- Step 5: Code signing ---");

my $cs_cmd = "codesign -f -s - \"$exe\" 2>&1";
$diag->("Running: $cs_cmd");
my $cs_out = `$cs_cmd`;
my $cs_exit = $? >> 8;
$diag->("codesign output: " . ( defined $cs_out ? "'$cs_out'" : '' ));
$diag->("codesign exit: $cs_exit");

# Step 6: Run the binary
$diag->("--- Step 6: Execute binary ---");

my $run = $exe;
if ( $exe !~ m{^/} && $exe !~ m{^\./} ) {
    $run = './' . $exe;
}
$diag->("Running: $run");

my $output = `$run 2>&1`;
my $run_exit  = $? >> 8;
my $run_sig   = $? & 127;
my $run_cored = $? & 128;
$diag->("stdout+stderr: " . ( defined $output ? "'$output'" : 'undef' ));
$diag->("Exit code: $run_exit, Signal: $run_sig, Core dump: " . ($run_cored ? 'yes' : 'no'));

if ( defined $output && $output eq '42' ) {
    pass "say 42 works on macOS ARM64";
}
else {
    $diag->("say 42 FAILED on macOS ARM64");

    # Step 7: Try even simpler programs
    $diag->("--- Step 7: Try simpler programs ---");

    for my $try ( 'exit 0;', 'say "";', 'say "x";' ) {
        my ( $tfh, $texe ) = File::Temp::tempfile( UNLINK => 0 );
        close $tfh;
        my $tp = Brocken::Compiler::Pipeline->new(
            debug => 4, parser => 'pratt', arch => $host_arch, os => $host_os
        );
        my $tok = eval { $tp->compile_source( $try, $texe, undef ); 1 };
        my $terr = $@;
        if ( !$tok ) {
            $diag->("  '$try' compilation FAILED: $terr");
            unlink $texe if -e $texe;
            next;
        }
        system("codesign -f -s - \"$texe\" >/dev/null 2>&1");
        my $toutput = `./$texe 2>&1`;
        my $texit = $? >> 8;
        my $tsig  = $? & 127;
        $diag->("  '$try' -> stdout='$toutput', exit=$texit, sig=$tsig");
        unlink $texe if -e $texe;
    }
}

# Cleanup
if ( -e $exe ) {
    chmod 0755, $exe;
    unlink $exe;
}

done_testing;
