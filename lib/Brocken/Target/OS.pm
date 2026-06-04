use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';

class Brocken::Target::OS {
    field $name : param : reader = '';
    ADJUST {
        die "Invalid OS: $name" unless $name =~ /^(?:linux|win64|macos|freebsd|openbsd|netbsd|solaris|dragonfly|midnightbsd|haiku)$/;
    }

    method is_posix () {
        return $self->name ne 'win64';
    }

    method is_bsd_like () {
        return $self->name =~ /^(?:macos|freebsd|openbsd|netbsd|dragonfly|midnightbsd)$/;
    }

    method uses_syscalls () {
        return $self->is_posix;
    }

    method exe_ext () {
        return $self->name eq 'win64' ? '.exe' : '';
    }

    method lib_ext () {
        return { win64 => '.dll', macos => '.dylib' }->{ $self->name } // '.so';
    }

    method exe_name ($base) {
        return $self->name eq 'win64' ? "./$base.exe" : "./$base";
    }

    method lib_name ($base) {
        my $ext = $self->lib_ext;
        return "$base$ext";
    }

    method syscall_write ($arch) {
        my $n = $self->name;
        if ( $n eq 'macos' ) {
            return $arch eq 'x64' ? 0x2000004 : 4;
        }
        return 1  if $n eq 'linux'      && $arch eq 'x64';
        return 64 if $n eq 'linux'      && $arch eq 'arm64';
        return 64 if $n eq 'linux'      && $arch eq 'riscv64';
        return 4  if $self->is_bsd_like && $arch eq 'x64';
        return 4  if $self->is_bsd_like && $arch eq 'arm64';
        return 4  if $self->is_bsd_like && $arch eq 'riscv64';
        return 4  if $n eq 'haiku';
        return undef;
    }

    method syscall_exit ($arch) {
        my $n = $self->name;
        if ( $n eq 'macos' ) {
            return $arch eq 'x64' ? 0x2000001 : 1;
        }
        return 60 if $n eq 'linux' && $arch eq 'x64';
        return 93 if $n eq 'linux' && $arch eq 'arm64';
        return 93 if $n eq 'linux' && $arch eq 'riscv64';
        return 1  if $self->is_bsd_like;
        return 1  if $n eq 'haiku';
        return undef;
    }

    method syscall_fork ($arch) {
        my $n = $self->name;
        if ( $n eq 'macos' ) {
            return $arch eq 'x64' ? 0x2000002 : 2;
        }
        return 57  if $n eq 'linux' && $arch eq 'x64';
        return 220 if $n eq 'linux' && $arch eq 'arm64';
        return 220 if $n eq 'linux' && $arch eq 'riscv64';
        return 2   if $n eq 'openbsd';
        return 2   if $self->is_bsd_like;
        return 2   if $n eq 'haiku';
        return undef;
    }

    method syscall_wait4 ($arch) {
        my $n = $self->name;
        if ( $n eq 'macos' ) {
            return $arch eq 'x64' ? 0x200000b : 11;
        }
        return 61  if $n eq 'linux' && $arch eq 'x64';
        return 260 if $n eq 'linux' && $arch eq 'arm64';
        return 260 if $n eq 'linux' && $arch eq 'riscv64';
        return 7   if $self->is_bsd_like;
        return undef;
    }

    method syscall_waitpid ($arch) {
        my $n = $self->name;
        if ( $n eq 'macos' ) {
            return $arch eq 'x64' ? 0x2000007 : 7;
        }
        return undef;
    }

    method syscall_getpid ($arch) {
        my $n = $self->name;
        if ( $n eq 'macos' ) {
            return $arch eq 'x64' ? 0x2000014 : 20;
        }
        return 39  if $n eq 'linux' && $arch eq 'x64';
        return 172 if $n eq 'linux' && $arch eq 'arm64';
        return 172 if $n eq 'linux' && $arch eq 'riscv64';
        return 20  if $self->is_bsd_like;
        return undef;
    }

    method syscall_clone ($arch) {
        my $n = $self->name;
        return 56  if $n eq 'linux' && $arch eq 'x64';
        return 220 if $n eq 'linux' && $arch eq 'arm64';
        return 220 if $n eq 'linux' && $arch eq 'riscv64';
        return undef;
    }

    method syscall_futex ($arch) {
        my $n = $self->name;
        return 202 if $n eq 'linux' && $arch eq 'x64';
        return 98  if $n eq 'linux' && $arch eq 'arm64';
        return 98  if $n eq 'linux' && $arch eq 'riscv64';
        return undef;
    }

    method syscall_mmap ($arch) {
        my $n = $self->name;
        return 9   if $n eq 'linux' && $arch eq 'x64';
        return 222 if $n eq 'linux' && $arch eq 'arm64';
        return 222 if $n eq 'linux' && $arch eq 'riscv64';
        return undef;
    }

    method write_mmap_args ( $as, $arch, $len ) {
        if ( $arch eq 'x64' ) {
            $as->mov_imm( 'rdi', 0 );       # addr
            $as->mov_imm( 'rsi', $len );    # len
            $as->mov_imm( 'rdx', 0x3 );     # prot (PROT_READ | PROT_WRITE)
            $as->mov_imm( 'r10', 0x22 );    # flags (MAP_PRIVATE | MAP_ANONYMOUS)
            $as->mov_imm( 'r8',  -1 );      # fd
            $as->mov_imm( 'r9',  0 );       # off
        }
        elsif ( $arch eq 'arm64' ) {
            $as->mov_imm( 'x0', 0 );
            $as->mov_imm( 'x1', $len );
            $as->mov_imm( 'x2', 0x3 );
            $as->mov_imm( 'x3', 0x22 );
            $as->mov_imm( 'x4', -1 );
            $as->mov_imm( 'x5', 0 );
        }
        elsif ( $arch eq 'riscv64' ) {
            $as->mov_imm( 'a0', 0 );
            $as->mov_imm( 'a1', $len );
            $as->mov_imm( 'a2', 0x3 );
            $as->mov_imm( 'a3', 0x22 );
            $as->mov_imm( 'a4', -1 );
            $as->mov_imm( 'a5', 0 );
        }
    }

    method syscall_rfork ($arch) {
        my $n = $self->name;
        return 465 if ( $n eq 'freebsd' || $n eq 'dragonfly' ) && $arch eq 'x64';
        return undef;
    }

    method syscall_bsdthread_create ($arch) {
        my $n = $self->name;
        return 0x2000168 if $n eq 'macos';
        return undef;
    }

    method syscall_lwp_create ($arch) {
        my $n = $self->name;

        # Solaris: _lwp_create (generic/x86/sparc)
        return 12 if $n eq 'solaris' && $arch eq 'x64';

        # NetBSD: _lwp_create
        return 309 if $n eq 'netbsd' && $arch eq 'x64';
        return undef;
    }

    method syscall_tfork ($arch) {
        my $n = $self->name;
        return 91 if $n eq 'openbsd';
        return undef;
    }

    method syscall_bsdthread_terminate ($arch) {
        my $n = $self->name;
        return 0x2000169 if $n eq 'macos';
        return undef;
    }

    method syscall_snooze ($arch) {
        my $n = $self->name;
        return $self->haiku_syscall( '_kern_snooze', $arch ) if $n eq 'haiku';
        return undef;
    }

    method syscall_nanosleep ($arch) {
        my $n = $self->name;
        return 0x2000065 if $n eq 'macos';
        return 35        if $n eq 'linux' && $arch eq 'x64';
        return 101       if $n eq 'linux' && $arch eq 'arm64';
        return 101       if $n eq 'linux' && $arch eq 'riscv64';
        return 430       if $n eq 'netbsd';
        return 37        if $n eq 'openbsd';
        return 199       if $n eq 'solaris';
        return 240       if $self->is_bsd_like;
        return undef;
    }

    method syscall_num_reg ($arch) {
        return 'rax' if $arch eq 'x64';
        return 'x16' if $self->name eq 'macos' && $arch eq 'arm64';
        return 'x8'  if $arch eq 'arm64';
        return 'a7'  if $arch eq 'riscv64';
        return undef;
    }

    method syscall_ret_reg ($arch) {
        return 'rax' if $arch eq 'x64';
        return 'x0'  if $arch eq 'arm64';
        return 'a0'  if $arch eq 'riscv64';
        return undef;
    }

    method syscall_exit_arg_reg ($arch) {
        return 'rdi' if $arch eq 'x64';
        return 'x0'  if $arch eq 'arm64';
        return 'a0'  if $arch eq 'riscv64';
        return undef;
    }

    method frame_reg ($arch) {
        return 'rbp' if $arch eq 'x64';
        return 'x29' if $arch eq 'arm64';
        return 's0'  if $arch eq 'riscv64';
        return undef;
    }

    method stack_reg ($arch) {
        return 'rsp' if $arch eq 'x64';
        return 'sp'  if $arch eq 'arm64';
        return 'sp'  if $arch eq 'riscv64';
        return undef;
    }

    method page_size ($arch) {
        return 0x1000;
    }

    sub detect_arch ($class) {
        my $os = $^O;
        if ( $os eq 'MSWin32' || $os eq 'cygwin' ) {
            my $pa  = $ENV{PROCESSOR_ARCHITECTURE} // '';
            my $paw = $ENV{PROCESSOR_ARCHITEW6432} // '';
            my $pi  = $ENV{PROCESSOR_IDENTIFIER}   // '';
            return 'arm64' if $pa =~ /ARM64/i || $paw =~ /ARM64/i || $pi =~ /ARM/i;
            return 'x64';
        }
        else {
            use Config;
            return 'arm64' if ( $Config{archname} // '' ) =~ /aarch64|arm64|apple-arm64/i;
            my $uname_m = `uname -m` // '';
            return 'arm64'   if $uname_m =~ /aarch64|arm64|armv8/i;
            return 'riscv64' if $uname_m =~ /riscv64/i;
            return 'x64';
        }
    }
    method text_rva () { return 0; }
    method data_rva () { return 0; }

    method write_syscall_args ( $as, $arch, $data_rva, $off, $text_rva, $len ) {
        if ( $arch eq 'arm64' ) {
            $as->lea_rva( 'x1', $data_rva + $off, $text_rva );
            $as->mov_imm( 'x2', $len );
        }
        elsif ( $arch eq 'riscv64' ) {
            $as->lea_rva( 'a1', $data_rva + $off, $text_rva );
            $as->mov_imm( 'a2', $len );
        }
        else {
            $as->lea_rva( 'rsi', $data_rva + $off, $text_rva );
            $as->mov_imm( 'rdx', $len );
        }
    }

    method haiku_syscall ( $name, $arch = 'x64' ) {
        return undef;
    }

    sub detect_host ($class) {
        my $n = 'linux';
        $n = 'win64'       if $^O eq 'MSWin32' || $^O eq 'cygwin';
        $n = 'macos'       if $^O eq 'darwin';
        $n = 'freebsd'     if $^O eq 'freebsd';
        $n = 'openbsd'     if $^O eq 'openbsd';
        $n = 'netbsd'      if $^O eq 'netbsd';
        $n = 'solaris'     if $^O eq 'solaris';
        $n = 'dragonfly'   if $^O eq 'dragonfly';
        $n = 'midnightbsd' if $^O eq 'midnightbsd';
        $n = 'haiku'       if $^O eq 'haiku';
        return $class->from_name($n);
    }

    sub from_name ( $class, $n ) {
        my $subclass = {
            linux       => 'Brocken::Target::OS::Linux',
            win64       => 'Brocken::Target::OS::Windows',
            macos       => 'Brocken::Target::OS::MacOS',
            freebsd     => 'Brocken::Target::OS::FreeBSD',
            openbsd     => 'Brocken::Target::OS::OpenBSD',
            netbsd      => 'Brocken::Target::OS::NetBSD',
            solaris     => 'Brocken::Target::OS::Solaris',
            dragonfly   => 'Brocken::Target::OS::Dragonfly',
            midnightbsd => 'Brocken::Target::OS::MidnightBSD',
            haiku       => 'Brocken::Target::OS::Haiku',
        }->{$n} // return __PACKAGE__->new( name => $n );
        eval "require $subclass" or die $@;
        return $subclass->new( name => $n );
    }
}
1;
