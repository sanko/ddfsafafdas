package Brocken::Codegen {
    use v5.40;
    use utf8;
    use feature 'class';
    no warnings 'portable', 'experimental::class';

    class Brocken::Codegen {
        field $arch : param;
        field $spill_count = 0; # Track unique IDs globally across spills

        method compile( $instructions, $driver ) {
            my $target = $driver->target;
            my $as     = $driver->as;

            # 1. Platform-neutral register allocation (with corrected spilling)
            my %reg_map = $self->_allocate_registers( $instructions, $driver );

            # 2. Platform-specific emission
            for my $inst (@$instructions) {
                my $op = $inst->{op};
                if    ($op eq 'label') { $as->mark_label($inst->{name}); }
                elsif ($op =~ /^intrinsic_/) {
                    $target->compile_intrinsic($as, $inst, \%reg_map, $driver);
                }
                else {
                    $target->emit_op($as, $inst, \%reg_map, $driver);
                }
            }
        }

        method _analyze_liveness($insts) {
            my %live;
            for (my $i=0; $i < @$insts; $i++) {
                my $ins = $insts->[$i];
                if (defined $ins->{dest} && $ins->{dest} =~ /^%/) {
                    $live{$ins->{dest}}{start} //= $i;
                    $live{$ins->{dest}}{end} = $i;
                }
                if ($ins->{op} eq 'cond_br' && defined $ins->{reg}) {
                    $live{$ins->{reg}}{end} = $i;
                }
                if (defined $ins->{args}) {
                    for my $arg (@{$ins->{args}}) {
                        if (defined $arg && !ref($arg) && $arg =~ /^%/) {
                            $live{$arg}{start} //= $i;
                            $live{$arg}{end} = $i;
                        }
                    }
                }
            }
            return %live;
        }

        # Corrected Spiller: Every load/store gets a UNIQUE local virtual register
        method _spill_vreg($insts, $vreg, $driver) {
            my $slot = $driver->alloc_local_slot();
            my @new;
            for my $old (@$insts) {
                my %ins = %$old;
                $ins{args} = [@{$old->{args}}] if $old->{args};

                my $needs_load = 0;
                my $load_reg;

                # If this instruction uses the spilled variable as an input
                if ($ins{args}) {
                    for (@{$ins{args}}) {
                        if (defined $_ && $_ eq $vreg) {
                            $needs_load = 1;
                            $load_reg = "%S" . ++$spill_count;
                            $_ = $load_reg;
                        }
                    }
                }
                if ($ins{op} eq 'cond_br' && defined $ins{reg} && $ins{reg} eq $vreg) {
                    $needs_load = 1;
                    $load_reg = "%S" . ++$spill_count;
                    $ins{reg} = $load_reg;
                }

                # Insert the load right before the use
                if ($needs_load) {
                    push @new, { op => 'local_load', dest => $load_reg, type => 'i64', args => [$slot] };
                }

                # If this instruction produces the spilled variable as an output
                my $needs_store = 0;
                my $store_reg;
                if (defined $ins{dest} && $ins{dest} eq $vreg) {
                    $needs_store = 1;
                    $store_reg = "%S" . ++$spill_count;
                    $ins{dest} = $store_reg;
                }

                push @new, \%ins;

                # Insert the store right after the production
                if ($needs_store) {
                    push @new, { op => 'local_store', type => 'void', args => [$slot, $store_reg] };
                }
            }
            @$insts = @new;
        }

        method _allocate_registers( $instructions, $driver ) {
            my $changed = 1;
            my %rmap;
            my $safety_val = 200; # Prevent absolute infinite loops

            while ($changed && $safety_val-- > 0) {
                $changed = 0;
                my %live = $self->_analyze_liveness($instructions);
                my @free = @{$driver->target->registers()};

                # Sort intervals by start position
                my @intervals = sort { $a->{start} <=> $b->{start} }
                                map  { {vreg => $_, %{$live{$_}}} }
                                keys %live;

                my @active;
                %rmap = ();

                for my $iv (@intervals) {
                    # Free up registers from variables that are no longer live
                    @active = grep {
                        if ($_->{end} < $iv->{start}) {
                            push @free, $_->{phys}; 0
                        } else { 1 }
                    } @active;

                    my $phys = shift @free;

                    if (!$phys) {
                        # SPILL! Find the active variable that ends furthest in the future
                        @active = sort { $b->{end} <=> $a->{end} } @active;
                        my $spill_target;

                        if ($active[0] && $active[0]->{end} > $iv->{end}) {
                            $spill_target = $active[0]->{vreg};
                        } else {
                            $spill_target = $iv->{vreg};
                        }

                        $self->_spill_vreg($instructions, $spill_target, $driver);
                        $changed = 1;
                        last; # Restart allocation with the new IR
                    }

                    $rmap{$iv->{vreg}} = $phys;
                    push @active, { vreg => $iv->{vreg}, phys => $phys, end => $iv->{end} };
                }
            }

            die "Register allocator failed: too many spills or infinite loop" if $safety_val <= 0;
            return %rmap;
        }
    }
}
1;
