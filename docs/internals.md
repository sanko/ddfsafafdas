# Brocken Internals

This document will eventually uh... document the internals of Brocken. Obviously.

This will also cover adding new keywords, IR instructions, OS platforms, optimizations, and types. Plus debugging tips at the end.

# Extending Brocken

I've attempted to organize this compiler so that adding new features is, on the surface, very easy.

Of course, this is subject to change.

## Adding new keywords

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

## Adding an IR Instruction

If you can't express your feature with existing opcodes:

### 1. Pick a name

No central registry. Use something descriptive like `atomic_add` or `load_field`.

### 2. Emit it from lowering

```perl
$builder->emit( 'my_new_op', 'Int', [ $arg1, $arg2 ] );
```

### 3. Handle it in every target

Add an `elsif` branch to `emit_op` in each `Target::*` module. Every target must handle it.

## Adding an OS Platform

### 1. Platform module

`lib/Brocken/Platform/YourOS.pm` - subclass `Brocken::Platform`:

```perl
class Brocken::Platform::YourOS : isa(Brocken::Platform) {
    method format_name() { return 'YourFormat'; }
    method shadow_space() { return 0; }
    method emit_intrinsic($target, $as, $inst, $reg_map, $driver) { ... }
}
```

Required intrinsics:
- `intrinsic_exit(code)` - terminate process
- `intrinsic_write(fd, buf, count)` - write bytes
- `intrinsic_alloc(size)` - allocate virtual memory

### 2. Format module

Subclass `Brocken::Format`. Implement `import_rva()` and `write_bin()`.

### 3. Wire it up

In `Compiler.pm` ADJUST:

```perl
if ($os eq 'youros') {
    require Brocken::Platform::YourOS;
    require Brocken::Format::YourFormat;
    $platform = Brocken::Platform::YourOS->new(...);
    $format   = Brocken::Format::YourFormat->new();
}
```

## Adding an Optimization

Optimizations go in `lib/Brocken/Compiler/Optimizer.pm`. Pattern:

```perl
method optimize($builder) {
    my @insts = $builder->instructions;
    $self->fuse_maps(\@insts);
    $self->dead_code_elim(\@insts);
    $builder->set_instructions(@insts);
}
```

Write a method that takes a reference to the instruction array, walks it looking for patterns, and transforms it in place. Call it from `optimize()`.

### Example: constant folding

Folding `constant 3, constant 4, add %1, %2` into `constant 7`:

```perl
method fold_constants(\@insts) {
    for (my $i = 0; $i < @insts; $i++) {
        next unless $insts[$i]{op} eq 'add';
        next unless $i >= 2;
        next unless $insts[$i-1]{op} eq 'constant'
                 && $insts[$i-2]{op} eq 'constant';
        my $l = $insts[$i-2]{args}[0];
        my $r = $insts[$i-1]{args}[0];
        splice @insts, $i-2, 3, {
            op => 'constant', type => 'Int',
            dest => $insts[$i]{dest}, args => [$l + $r]
        };
        $i -= 2;
    }
}
```

## Adding a Type

Types are just strings: `Int`, `String`, `Any`, `Bool`, `Class`. To add one:

1. Add it to `%KEYWORDS` in the lexer.
2. Update `_parse_type_spec` in `Parser.pm` to recognize it.
3. Handle it in `Lowering.pm`: variable declarations (unboxed or tagged?), `M_print_any` (new tag case), binary ops (type checking), GC (does it hold pointers?).
4. If it has literal constants, update `DataSegment`.

## Debugging

### IR dump

After lowering:

```perl
$lowering->builder->dump_ir("AFTER LOWERING");
```

Prints every instruction with vregs. Catches most bugs.

### Hex dump

```perl
my $code_bytes = $p->as->code;
for (my $i=0; $i < length($code_bytes); $i += 16) {
    printf("%04X: %-40s\n", $i, unpack("H*", substr($code_bytes, $i, 16)));
}
```

### GDB (Linux)

```bash
gdb ./brocken_out
(gdb) break *0x140001000
(gdb) run
(gdb) info registers
(gdb) x/20i $rip
```

### Common screw-ups

- **Stack alignment**: x64 ABI needs RSP 16-byte aligned before `call`. If printf crashes, that's why.
- **Volatile registers**: Don't put long-lived values in rax, rcx, rdx, r8-r11. They get clobbered.
- **Missing labels**: Jump to 0x0 = referenced a label that doesn't exist. Check `load_func_addr` targets.
- **Shadow stack mismatch**: Every `shadow_push` needs a matching `shadow_set` on the exit path.
- **GC re-entrancy**: The collector allocates memory. The `gc_cycle` counter guards against infinite recursion.
