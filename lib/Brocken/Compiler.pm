package Brocken::Compiler {
    use v5.40;
    use utf8;
    use feature 'class';
    no warnings 'portable', 'experimental::class';

    class Brocken::Symbol {
        field $name           : param : reader;
        field $type           : param : reader;
        field $is_state       : param : reader = 0;
        field $state_idx      : param : reader = undef;
        field $stack_offset   : param : reader = undef;
        field $shadow_offset  : param : reader = undef;
        field $isolate_offset : param : reader = undef;
    }

    class Brocken::Scope {
        field $parent : param : reader = undef;
        field %symbols;

        method define( $name, $type, $is_state = 0, $state_idx = undef, $stack_offset = undef, $shadow_offset = undef, $isolate_offset = undef ) {
            die "Semantic Error: Redeclaration of $name\n" if exists $symbols{$name};
            return $symbols{$name} = Brocken::Symbol->new(
                name           => $name,
                type           => $type,
                is_state       => $is_state,
                state_idx      => $state_idx,
                stack_offset   => $stack_offset,
                shadow_offset  => $shadow_offset,
                isolate_offset => $isolate_offset
            );
        }
        method has_local_symbol($name) { return exists $symbols{$name}; }
        method resolve($name)          { return $symbols{$name} // ( $parent ? $parent->resolve($name) : undef ); }
    }

    class Brocken::Compiler {
        field $arch  : param : reader = undef;
        field $os    : param : reader = undef;
        field $type  : param : reader = 'exe';
        field $debug : param : reader = 0;
        #
        field $target   : reader;
        field $platform : reader;
        field $as       : reader;
        field $format   : reader;
        #
        field $local_ptr = 0;
        field @source_locs;
        field @func_ranges;
        #
        field $source_file            : reader : writer = 'source.brocken';
        field $line_table_ptr_offset  : reader : writer = undef;
        field $line_table_size_offset : reader : writer = undef;
        #
        field %debug_func_params;
        field %debug_func_locals;
        #
        field $global_iso_offset      : reader : writer = undef;
        field $exception_table_offset : reader : writer = undef;
        field $data_segment           : reader : writer = undef;
        field $coverage               : param  : reader = undef;
        field $coverage_table_offset      : reader = undef;
        field $coverage_table_size        : reader = undef;
        field $coverage_probe_lines       : reader = undef;
        #
        ADJUST {
            my $detected_os = $^O eq 'MSWin32' ? 'win64' : ( $^O eq 'darwin' ? 'macos' : 'linux' );
            $os //= $detected_os;
            my $detected_arch = 'x64';
            if ( $^O eq 'MSWin32' ) {
                $detected_arch = ( ( $ENV{PROCESSOR_ARCHITECTURE} // '' ) =~ /ARM64/i ) ? 'arm64' : 'x64';
            }
            else {
                my $m = `uname -m` // 'x86_64';
                $detected_arch = 'arm64' if $m =~ /aarch64|arm64|armv8/i;
            }
            $arch //= $detected_arch;
            if ( $os eq 'win64' ) {
                require Brocken::Platform::Windows;
                require Brocken::Format::PE;
                $platform = Brocken::Platform::Windows->new( os => $os );
                $format   = Brocken::Format::PE->new( type => $type );
            }
            elsif ( $os =~ /^(linux|freebsd|openbsd|netbsd|dragonfly)$/ ) {
                require Brocken::Platform::Linux;
                require Brocken::Format::ELF;
                $platform = Brocken::Platform::Linux->new( os => $os );
                $format   = Brocken::Format::ELF->new( type => $type );
            }
            elsif ( $os eq 'macos' ) {
                require Brocken::Platform::Darwin;
                require Brocken::Format::MachO;
                $platform = Brocken::Platform::Darwin->new( os => $os );
                $format   = Brocken::Format::MachO->new( type => $type );
            }
            if ( $arch eq 'x64' ) {
                require Brocken::Target::X64;
                $target = Brocken::Target::X64->new( os => $os, arch => $arch );
                $as     = Brocken::Target::X64::Emit->new();
            }
            else {
                require Brocken::Target::ARM64;
                $target = Brocken::Target::ARM64->new( os => $os, arch => $arch );
                $as     = Brocken::Target::ARM64::Emit->new();
            }
        }

        method preserved_regs() {
            if ( $arch eq 'x64' ) {
                return $os eq 'win64' ? [qw(rbp rbx rdi rsi r12 r13 r15)] : [qw(rbp rbx r12 r13 r15)];
            }
            return [qw(x19 x20 x21 x22 x23 x24 x25 x26 x27 x29 x30)];
        }

        method context_size() {
            my $multiplier = $arch eq 'arm64' ? 16 : 8;
            return scalar( @{ $self->preserved_regs() } ) * $multiplier;
        }

        method rip_offset() {
            return $arch eq 'arm64' ? 0 : $self->context_size();
        }

        method prev_bp_offset() {
            return $arch eq 'arm64' ? 16 : $self->context_size() - 8;
        }

        method frame_local_size() {
            my $locals = 4096;
            my $ctx    = $self->context_size();
            my $shadow = $platform->shadow_space();
            my $total  = $locals + $shadow;
            return ( $total + 15 ) & ~15;
        }
        method text_rva ()                                { $format->rva_for('.text') }
        method data_rva ()                                { $format->rva_for('.data') }
        method import_rva ($name)                         { $format->import_rva($name) }
        method source_locs ()                             { return @source_locs; }
        method push_source_loc ( $o, $l, $c, $f = undef ) { push @source_locs, { offset => $o, line => $l, col => $c, file => $f }; }
        method func_ranges ()                             { return @func_ranges; }
        method push_func_range ($r)                       { push @func_ranges, $r; }
        method clear_func_ranges ()                       { @func_ranges = (); }
        method set_debug_func_params ( $n, $p ) { $debug_func_params{$n} = $p; }
        method get_debug_func_params ($n)       { $debug_func_params{$n} // [] }
        method set_debug_func_locals ( $n, $l ) { $debug_func_locals{$n} = $l; }
        method get_debug_func_locals ($n)       { $debug_func_locals{$n} // [] }
        method close_last_func_range ($e)       { $func_ranges[-1]{end} = $e if @func_ranges; }
        method local_ptr ()       {$local_ptr}
        method set_local_ptr ($v) { $local_ptr = $v }
        method reset_locals ()    { $local_ptr = 0 }

        method alloc_local_slot () {
            $local_ptr += 8;
            die 'Stack Overflow: Local area exceeded 4096 bytes' if $local_ptr > 4096;
            return $local_ptr;
        }

        method iso_offset ($name) {
            state $ISO = {
                heap_ptr          => 0,
                heap_limit        => 8,
                state_ptr         => 16,
                current_fcb       => 24,
                fiber_head        => 32,
                heap_base         => 40,
                block_cursor      => 48,
                block_limit       => 56,
                free_blocks       => 64,
                recyclable_blocks => 72,
                gc_cycle          => 80,
                heap_min          => 88,
                heap_max          => 96,
                mark_stack_base   => 104,
                mark_stack_ptr    => 112,

                # sandbox starts here
                fuel             => 120,    # Remaining instruction/tick count
                mem_limit        => 128,    # Maximum allowed heap bytes
                mem_used         => 136,    # Current total heap bytes mapped
                capabilities     => 144,    # A 64-bit bitmask of allowed operations
                err_code         => 152,    # Reason for sandbox termination (0=Success, 1=OOM, 2=NoFuel, 3=Security)
                mark_stack_limit => 160,
                exception_table  => 168,

                # System Globals
                stdout_handle => 176,
                stderr_handle => 184,
                stdin_handle  => 192,
                env_hash      => 200,
                argv_array    => 208,
                def_var       => 216        # $_
            };
            return $ISO->{$name} // die "Unknown Isolate offset: $name";
        }

        method fcb_offset ($name) {
            state $FCB
                = { sp => 0, stack_base => 8, shadow_base => 24, shadow_ptr => 32, caller => 40, next => 48, wait_handle => 56, exception_obj => 64 };
            return $FCB->{$name};
        }

        method cc ($name) {
            return $arch eq 'x64' ? { eq => 4, ne => 5, lt => 0xC, gt => 0xF, z => 4, nz => 5 }->{$name} :
                { eq => 0, ne => 1, lt => 0xB, gt => 0xC }->{$name};
        }
        {
            my $_x = 0;

            method compile_source( $source, $output_file, $filename = 'eval_' . ++$_x ) {
                require Brocken::Lexer;
                require Brocken::Parser;
                require Brocken::Compiler::Lowering;
                require Brocken::Codegen;
                require Brocken::Compiler::DataSegment;
                $source_file = $filename;
                my $tokens   = Brocken::Lexer->new( source => $source, file => $filename )->lex();
                my $ast      = Brocken::Parser->new( tokens => $tokens )->parse();
                my $ds       = Brocken::Compiler::DataSegment->new();
                my $lowering = Brocken::Compiler::Lowering->new( data_segment => $ds, driver => $self );
                $lowering->lower_program($ast);
                my @instructions = $lowering->builder->instructions();
                my $probe_count  = 0;

                if ( $self->coverage ) {
                    require Brocken::Compiler::Optimizer;
                    my $opt = Brocken::Compiler::Optimizer->new();
                    $probe_count = $opt->insert_coverage_probes( \@instructions );
                    if ( $probe_count > 0 ) {
                        $coverage_table_size   = $probe_count;
                        $coverage_table_offset = $ds->add_raw_bytes( "\0" x $probe_count );

                        my @probe_lines;
                        my $next_line = 0;
                        for my $inst ( reverse @instructions ) {
                            if ( $inst->{op} eq 'source_loc' ) {
                                $next_line = $inst->{args}[0];
                            }
                            elsif ( $inst->{op} eq 'coverage_probe' ) {
                                $probe_lines[ $inst->{args}[0] ] = $next_line;
                            }
                        }
                        $coverage_probe_lines = \@probe_lines;
                    }
                }
                $self->format->pre_layout( scalar(@instructions) * 64 + 8192, length( $ds->raw_data ) + 16384, $arch, $os, $debug );
                my $codegen = Brocken::Codegen->new( arch => $arch );
                $codegen->compile( \@instructions, $self );
                $self->as->resolve( $self->text_rva, $self->data_rva );
                $self->format->set_func_ranges( [ $self->func_ranges ] );
                $self->format->set_labels( $self->as->labels );
                $self->format->set_labels( $self->as->labels );
                $self->format->set_exported_funcs( $lowering->exported_funcs );

                if ( $self->debug ) {
                    $self->format->set_func_ranges( [ $self->func_ranges ] );
                    require Brocken::Format::DWARF;
                    my $dwarf = Brocken::Format::DWARF->new(
                        source_locs    => [ $self->source_locs ],
                        text_base      => $self->format->image_base + $self->text_rva,
                        func_ranges    => [ $self->func_ranges ],
                        context_size   => $self->context_size,
                        arch           => $self->arch,
                        preserved_regs => $self->preserved_regs,
                        class_info     => { $lowering->class_info },
                        source_file    => $filename
                    );
                    my $dwarf_data = $dwarf->build_all();
                    $self->format->set_debug_data($dwarf_data);
                    for my $sec ( keys %$dwarf_data ) {
                        eval { $self->format->layout->get($sec)->{size} = length( $dwarf_data->{$sec} ) };
                    }
                    $self->format->layout->calculate( $os eq 'macos' ? 0x4000 : 0x1000 );
                }
                $self->format->set_preserved_regs( $self->preserved_regs );
                $self->format->write_bin( $output_file, $self->as->code, $ds->raw_data(), $arch, $os, $type );
                return $output_file;
            }
        }
    }
}
1;
