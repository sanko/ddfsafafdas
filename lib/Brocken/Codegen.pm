use v5.40;
use utf8;
use feature 'class';
no warnings 'experimental::class';

class Brocken::Codegen {
    field $arch : param;
    field $spill_count = 0;

    # Start spills at a high offset to avoid clashing with function locals
    field $spill_slot_ptr = 2048;

    # In lib/Brocken/Codegen.pm (inside Class Brocken::Codegen)
    method compile( $instructions, $driver ) {
        my $target  = $driver->target;
        my $as      = $driver->as;
        my %reg_map = $self->_allocate_registers( $instructions, $driver );
        $driver->clear_func_ranges;
        for my $i ( 0 .. $#$instructions ) {
            my $inst = $instructions->[$i];
            my $op   = $inst->{op};
            if ( $op eq 'label' ) {
                my $is_func = $i + 1 < @$instructions && $instructions->[ $i + 1 ]{op} =~ /^enter_(?:leaf_)?func$/;
                if ($is_func) {
                    $driver->close_last_func_range( length( $as->code ) );

                    # FIX: Initialize local_ptr to the exact lowered size of this specific function
                    # to prevent stack overlap and memory corruption!
                    my $func_size = $driver->get_func_local_size( $inst->{name} );
                    $driver->set_local_ptr($func_size);

                    # Pre-scan and allocate dynamic stack_alloc slots strictly after lowered locals
                    my $scan_idx = $i + 2;
                    while ( $scan_idx < @$instructions ) {
                        my $s_inst = $instructions->[$scan_idx];
                        last if $s_inst->{op} =~ /^enter_(?:leaf_)?func$/;
                        if ( $s_inst->{op} eq 'stack_alloc' ) {
                            my $aligned_sz = $s_inst->{args}[1];
                            my $slot       = $driver->alloc_local_chunk($aligned_sz);
                            $s_inst->{slot} = $slot;
                        }
                        $scan_idx++;
                    }
                    my $fr     = { name => $inst->{name}, start => length( $as->code ), ctx_size => $driver->context_size, try_ranges => [] };
                    my $params = $driver->get_debug_func_params( $inst->{name} );
                    $fr->{params} = $params if @$params;
                    my $locals = $driver->get_debug_func_locals( $inst->{name} );
                    $fr->{locals} = $locals if @$locals;
                    $driver->push_func_range($fr);
                }
                $as->mark_label( $inst->{name} );
            }
            elsif ( $op eq 'mark_try_start' ) {
                my $fr = ( $driver->func_ranges )[-1];
                push @{ $fr->{try_ranges} },
                    { id => $inst->{args}[0], start => length( $as->code ), catch_label => $inst->{args}[1], finally_label => $inst->{args}[2] };
            }
            elsif ( $op eq 'mark_try_end' ) {
                my $fr = ( $driver->func_ranges )[-1];
                for my $tr ( @{ $fr->{try_ranges} } ) {
                    if ( $tr->{id} == $inst->{args}[0] ) {
                        $tr->{end} = length( $as->code );
                    }
                }
            }
            elsif ( $op eq 'source_loc' ) { $driver->push_source_loc( length( $as->code ), $inst->{args}[0], $inst->{args}[1], $inst->{args}[2] ); }
            elsif ( $op eq 'coverage_probe' ) {
                if ( $driver->coverage && defined $driver->coverage_table_offset ) {
                    my $probe_id = $inst->{args}[0];
                    $as->inc_byte_data( $driver->coverage_table_offset + $probe_id );
                }
            }
            elsif ( $op =~ /^intrinsic_/ ) { $target->compile_intrinsic( $as, $inst, \%reg_map, $driver ); }
            else                           { $target->emit_op( $as, $inst, \%reg_map, $driver ); }
        }
        $driver->close_last_func_range( length( $as->code ) );

        # Finalize Exception Table in Data Segment
        if ( $driver->data_segment ) {
            my $extab = pack( 'Q<', scalar( $driver->func_ranges ) );
            for my $fr ( $driver->func_ranges ) {
                $extab .= pack( 'Q< Q< Q<', $fr->{start}, $fr->{end}, scalar( @{ $fr->{try_ranges} } ) );
                for my $tr ( reverse @{ $fr->{try_ranges} } ) {
                    $extab .= pack( 'Q< Q< Q< Q<',
                        $tr->{start}, $tr->{end},
                        ( $tr->{catch_label}   ? $as->labels->{ $tr->{catch_label} }   : 0 ),
                        ( $tr->{finally_label} ? $as->labels->{ $tr->{finally_label} } : 0 ) );
                }
            }
            my $off = $driver->data_segment->add_raw_bytes($extab);

            # --- Serialize and Append Runtime Line Table ---
            my @locs     = sort { $a->{offset} <=> $b->{offset} } $driver->source_locs;
            my $rlt_data = '';
            for my $loc (@locs) {
                my $file_rva = 0;
                if ( defined $loc->{file} ) {
                    $file_rva = $driver->data_segment->add_string( $loc->{file} );
                }
                $rlt_data .= pack( 'Q< Q< Q< Q<', $loc->{offset}, $loc->{line}, $loc->{col}, $file_rva );
            }
            my $rlt_off = $driver->data_segment->add_raw_bytes($rlt_data);
            my $raw     = $driver->data_segment->raw_data();

            # Patch the pointer to the exception table
            substr( $raw, $driver->exception_table_offset, 8, pack( 'Q<', $off ) );

            # Patch line table ptr and size offsets
            if ( defined $driver->line_table_ptr_offset ) {
                substr( $raw, $driver->line_table_ptr_offset, 8, pack( 'Q<', $rlt_off ) );
            }
            if ( defined $driver->line_table_size_offset ) {
                substr( $raw, $driver->line_table_size_offset, 8, pack( 'Q<', scalar(@locs) ) );
            }
            $driver->data_segment->set_raw_data($raw);
        }
    }

    method _analyze_liveness($insts) {
        my %live;
        my %label_idx;
        for ( my $i = 0; $i < @$insts; $i++ ) {
            my $ins = $insts->[$i];
            if ( $ins->{op} eq 'label' ) {
                $label_idx{ $ins->{name} } = $i;
            }
            if ( defined $ins->{dest} && $ins->{dest} =~ /^%/ ) {
                $live{ $ins->{dest} }{start} //= $i;
                $live{ $ins->{dest} }{end} = $i;
            }
            if ( $ins->{op} eq 'cond_br' && defined $ins->{reg} && $ins->{reg} =~ /^%/ ) {
                $live{ $ins->{reg} }{start} //= $i;
                $live{ $ins->{reg} }{end} = $i;
            }
            if ( defined $ins->{args} ) {
                for my $arg ( @{ $ins->{args} } ) {
                    if ( defined $arg && !ref($arg) && $arg =~ /^%/ ) {
                        $live{$arg}{start} //= $i;
                        $live{$arg}{end} = $i;
                    }
                }
            }
        }
        my $changed = 1;
        while ($changed) {
            $changed = 0;
            for ( my $i = 0; $i < @$insts; $i++ ) {
                my $ins = $insts->[$i];
                if ( $ins->{op} eq 'jmp' || $ins->{op} eq 'cond_br' ) {
                    my @targets;
                    push @targets, $ins->{target}  if defined $ins->{target};
                    push @targets, $ins->{true_l}  if defined $ins->{true_l};
                    push @targets, $ins->{false_l} if defined $ins->{false_l};
                    for my $t (@targets) {
                        my $target_idx = $label_idx{$t};
                        if ( defined $target_idx && $target_idx < $i ) {
                            for my $v ( keys %live ) {
                                if ( $live{$v}{start} <= $target_idx && $live{$v}{end} >= $target_idx ) {
                                    if ( $live{$v}{end} < $i ) {
                                        $live{$v}{end} = $i;
                                        $changed = 1;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return %live;
    }

    method _spill_vreg( $insts, $vreg, $driver ) {
        my $slot = $spill_slot_ptr;
        $spill_slot_ptr += 8;
        die "Stack Overflow: Spill area exceeded frame size" if $spill_slot_ptr > 4000;
        my @new;
        for my $old (@$insts) {
            my %ins = %$old;
            $ins{args} = [ @{ $old->{args} } ] if $old->{args};
            my ( $needs_l, $l_reg, $needs_s, $s_reg ) = ( 0, undef, 0, undef );
            if ( $ins{args} ) {
                for ( @{ $ins{args} } ) {
                    if ( defined $_ && $_ eq $vreg ) { $needs_l = 1; $l_reg = "%S" . ++$spill_count; $_ = $l_reg; }
                }
            }
            if ( $ins{op} eq 'cond_br' && defined $ins{reg} && $ins{reg} eq $vreg ) {
                $needs_l  = 1;
                $l_reg    = "%S" . ++$spill_count;
                $ins{reg} = $l_reg;
            }
            push @new, { op => 'local_load', dest => $l_reg, type => 'i64', args => [$slot] } if $needs_l;
            if ( defined $ins{dest} && $ins{dest} eq $vreg ) { $needs_s = 1; $s_reg = "%S" . ++$spill_count; $ins{dest} = $s_reg; }
            push @new, \%ins;
            push @new, { op => 'local_store', type => 'void', args => [ $slot, $s_reg ] } if $needs_s;
        }
        @$insts = @new;
    }

    method _allocate_registers( $instructions, $driver ) {
        my $changed = 1;
        my %rmap;
        my $safety = 2000;
        my %spilled;
        while ( $changed && $safety-- > 0 ) {
            $changed = 0;
            %spilled = ();
            my %live      = $self->_analyze_liveness($instructions);
            my @free      = @{ $driver->target->registers() };
            my @intervals = sort { $a->{start} <=> $b->{start} } map { { vreg => $_, %{ $live{$_} } } } keys %live;
            my @active;
            %rmap = ();
            my $i = 0;

            while ( $i < @intervals ) {
                my $iv = $intervals[$i];
                @active = grep {
                    if ( $_->{end} < $iv->{start} ) { push @free, $_->{phys}; 0 }
                    else                            {1}
                } @active;
                my $phys = shift @free;
                if ( !$phys ) {
                    @active = sort { $b->{end} <=> $a->{end} } @active;
                    if ( $active[0] && $active[0]->{end} > $iv->{end} ) {

                        # Spill an already-allocated vreg to free its register for the current vreg
                        $spilled{ $active[0]->{vreg} } = 1;
                        my $freed = $active[0]->{phys};
                        @active = grep { $_->{vreg} ne $active[0]->{vreg} } @active;
                        unshift @free, $freed;
                        $changed = 1;
                        redo;
                    }
                    else {
                        # Spill current vreg — skip it
                        $spilled{ $iv->{vreg} } = 1;
                        $changed = 1;
                        $i++;
                        next;
                    }
                }
                $rmap{ $iv->{vreg} } = $phys;
                push @active, { vreg => $iv->{vreg}, phys => $phys, end => $iv->{end} };
                $i++;
            }
            for my $sv ( keys %spilled ) {
                $self->_spill_vreg( $instructions, $sv, $driver );
            }
        }
        return %rmap;
    }
}
1;
__END__

=pod

=head1 NAME

Brocken::Codegen - Linear scan register allocator and instruction dispatcher

=head1 SYNOPSIS

    my $codegen = Brocken::Codegen->new( arch => 'x64' );
    $codegen->compile( \@instructions, $driver );

=head1 DESCRIPTION

Performs liveness analysis on the IR instruction sequence, then runs linear scan register allocation. Spills to local
stack slots when the register pool is exhausted. Iterates until convergence (typically 2-3 rounds).

After allocation, dispatches each instruction to the target backend's C<emit_op> (or C<compile_intrinsic> for
OS-specific ops).

=head1 METHODS

=head2 compile($instructions, $driver)

  my $codegen = Brocken::Codegen->new( arch => $arch );
  $codegen->compile( \@instructions, $driver );

Allocates registers and emits machine code via the driver's target emitter.

=cut
