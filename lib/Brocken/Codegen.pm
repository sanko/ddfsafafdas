package Brocken::Codegen {
    use v5.40;
    use utf8;
    use feature 'class';
    no warnings 'experimental::class';

    class Brocken::Codegen {
        field $arch : param;
        field $spill_count = 0;

        method compile( $instructions, $driver ) {
            my $target  = $driver->target;
            my $as      = $driver->as;
            my %reg_map = $self->_allocate_registers( $instructions, $driver );
            $driver->clear_func_ranges;
            for my $i ( 0 .. $#$instructions ) {
                my $inst = $instructions->[$i];
                my $op   = $inst->{op};
                if ( $op eq 'label' ) {
                    my $is_func = $i + 1 < @$instructions && $instructions->[ $i + 1 ]{op} eq 'enter_func';
                    if ($is_func) {
                        $driver->close_last_func_range( length( $as->code ) );
                        my $fr     = { name => $inst->{name}, start => length( $as->code ), ctx_size => $driver->context_size };
                        my $params = $driver->get_debug_func_params( $inst->{name} );
                        $fr->{params} = $params if @$params;
                        my $locals = $driver->get_debug_func_locals( $inst->{name} );
                        $fr->{locals} = $locals if @$locals;
                        $driver->push_func_range($fr);
                    }
                    $as->mark_label( $inst->{name} );
                }
                elsif ( $op eq 'source_loc' )  { $driver->push_source_loc( length( $as->code ), $inst->{args}[0], $inst->{args}[1] ); }
                elsif ( $op =~ /^intrinsic_/ ) { $target->compile_intrinsic( $as, $inst, \%reg_map, $driver ); }
                else                           { $target->emit_op( $as, $inst, \%reg_map, $driver ); }
            }
            $driver->close_last_func_range( length( $as->code ) );
        }

        method _analyze_liveness($insts) {
            my %live;
            for ( my $i = 0; $i < @$insts; $i++ ) {
                my $ins = $insts->[$i];
                if ( defined $ins->{dest} && $ins->{dest} =~ /^%/ ) { $live{ $ins->{dest} }{start} //= $i; $live{ $ins->{dest} }{end} = $i; }
                if ( $ins->{op} eq 'cond_br' && defined $ins->{reg} ) { $live{ $ins->{reg} }{end} = $i; }
                if ( defined $ins->{args} ) {
                    for my $arg ( @{ $ins->{args} } ) {
                        if ( defined $arg && !ref($arg) && $arg =~ /^%/ ) { $live{$arg}{start} //= $i; $live{$arg}{end} = $i; }
                    }
                }
            }
            return %live;
        }

        method _spill_vreg( $insts, $vreg, $driver ) {
            my $slot = $driver->alloc_local_slot();
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
            while ( $changed && $safety-- > 0 ) {
                $changed = 0;
                my %live      = $self->_analyze_liveness($instructions);
                my @free      = @{ $driver->target->registers() };
                my @intervals = sort { $a->{start} <=> $b->{start} } map { { vreg => $_, %{ $live{$_} } } } keys %live;
                my @active;
                %rmap = ();
                for my $iv (@intervals) {
                    @active = grep {
                        if ( $_->{end} < $iv->{start} ) { push @free, $_->{phys}; 0 }
                        else                            {1}
                    } @active;
                    my $phys = shift @free;
                    if ( !$phys ) {
                        @active = sort { $b->{end} <=> $a->{end} } @active;
                        my $spill = ( $active[0] && $active[0]->{end} > $iv->{end} ) ? $active[0]->{vreg} : $iv->{vreg};
                        $self->_spill_vreg( $instructions, $spill, $driver );
                        $changed = 1;
                        last;
                    }
                    $rmap{ $iv->{vreg} } = $phys;
                    push @active, { vreg => $iv->{vreg}, phys => $phys, end => $iv->{end} };
                }
            }
            return %rmap;
        }
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
}
1;
