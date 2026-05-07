# Brocken Internals

This document will eventually uh... document the internals of Brocken. Obviously.

# Extending Brocken

I've attempted to organize this compiler so that adding new features is, on the surface, very easy.

Of course, this is subject to change.

# Adding new keywords

For this example, let's pretend we're adding the `defer` keyword.

```perl
sub test_defer() {
     say "Entering function...";
     defer {
         say "   [Defer] Executing cleanup 1 (LIFO)";
     }
     defer {
         say "   [Defer] Executing cleanup 2 (LIFO)";
     }
     say "Doing work...";
     return 42;
}

say test_defer();
```

When we're finished, this would output:

```
Entering function...
Doing work...
  [Defer] Executing cleanup 2 (LIFO)
  [Defer] Executing cleanup 1 (LIFO)
```

To implement `defer`, we need to update the Lexer to recognize the keyword, the Parser to handle the new statement, and the Lowering engine to manage a LIFO stack of cleanup fragments that get injected before any return or at the end of a routine.

1) Add `defer` to the keyword list in `Brocken::Lexer`.

```perl
    my %KEYWORDS = map { $_ => 1 } qw[
        my our state
        class method field
        return exit
        sub
        fiber yield
        defer
        if else unless
        while for map
        say print
        Int String Any Bool
        true false
    ];
```
2) Update the AST.

Organizationally, you should find the best place for your keyword. For `defer`, we'll just tos it into `Brocken::AST::Stmt`.

```perl
class Brocken::AST::Stmt::Defer : isa(Brocken::AST::Node) { field $block : param : reader;  }
```
3) Update our parser.

Register the handler and implement the parsing logic. This will require adding to the `%STMT_HANDLERS` hash in `Brocken::Parser`.

```perl
    my %STMT_HANDLERS = (
        # ...
        'defer' => '_parse_defer'
        #...
    );
```

And then implement the method:

```perl
method _parse_defer() {
    $self->advance(); # Consumes the 'defer' keyword
    my $block = $self->_parse_block_stmt(); # Use this if your keyword is a block statement like `sub` or `class`
    return Brocken::AST::Stmt::Defer->new( block => $block );
}
```

4) Update Lowering.pm.

This is where the logic lives. Your keyword will obviously be different but for our `defer` keyword, we need a stack to track deferred blocks for the current function scope.

You'll add code like this to Brocken::Compiler::Lowering:

```perl
field @defer_stack; # Stack of [ \@instructions ]

# Helper to emit all currently deferred actions
method _emit_all_defers() {
    # LIFO: Reverse the stack
    for my $fragment (reverse @defer_stack) {
        $builder->push_instruction($_) for @$fragment;
    }
}

# The Defer visitor
method lower_Defer($node) {
    # We "capture" the instructions of the block without emitting them yet
    my @saved_instructions = $builder->instructions;
    $builder->set_instructions(); # Clear temporarily

    $self->lower($node->block);

    my @deferred_instructions = $builder->instructions;
    $builder->set_instructions(@saved_instructions); # Restore

    # Push onto the LIFO stack for this routine
    push @defer_stack, \@deferred_instructions;
    return (undef, 'void');
}

# Update lower_Return to trigger defers
method lower_Return($node) {
    die "Return outside sub" if $routine_depth == 0;
    my ( $rv, $ty ) = $self->lower( $node->expr );

    # The reason we're all  here:
    $self->_emit_all_defers();

    if ( $routine_types[-1] eq 'fiber' ) {
        my $fcb = $builder->emit( 'load_iso_disp', 'ptr', [ $driver->iso_offset('current_fcb') ] );
        $builder->emit( 'call_func', 'Any',
            [ 'M_fiber_switch', $builder->emit( 'load_mem_disp', 'ptr', [ $fcb, $driver->fcb_offset('caller') ] ), $rv ] );
        $builder->emit( 'intrinsic_exit', 'void', [0] );
    }
    else { $builder->emit( 'leave_func', 'void', [$rv] ); }
    return (undef, 'void');
}

# Update routine handlers to localize the defer stack
# This applies to lower_Method, lower_ClassDecl (methods), and lower_AnonSub
```

Remember that you're personally responsible for making this work correctly.To ensure `defer` stacks don't leak between nested functions or across class methods, you must wrap your routine lowering like this:

```perl
# Inside lower_Method (and similar routine lowering methods)
method lower_Method($node) {
    push @routine_types, 'method';
    my @old_defers = @defer_stack; # Localize stack
    @defer_stack = ();

    # ... existing setup code ...

    $self->lower_block( $node->body->statements );

    # Handle implicit return at end of block
    $self->_emit_all_defers();
    $builder->emit( 'leave_func', 'void', [0] );

    # ... existing cleanup code ...
    @defer_stack = @old_defers; # Restore stack
    pop @routine_types;
}
```
