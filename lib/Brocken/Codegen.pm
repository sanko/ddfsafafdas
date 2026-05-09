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
            for my $inst (@$instructions) {
                my $op = $inst->{op};
                if    ( $op eq 'source_loc' )  { $driver->push_source_loc( length( $as->code ), $inst->{args}[0], $inst->{args}[1] ); }
                elsif ( $op eq 'label' )       { $as->mark_label( $inst->{name} ); }
                elsif ( $op =~ /^intrinsic_/ ) { $target->compile_intrinsic( $as, $inst, \%reg_map, $driver ); }
                else                           { $target->emit_op( $as, $inst, \%reg_map, $driver ); }
            }
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
            my $safety = 200;
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
