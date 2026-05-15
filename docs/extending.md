# Extending Brocken

This guide covers adding new features to the Brocken compiler. For adding new keywords, IR instructions, types, platforms, optimizations, and runtime modifications.

## Adding new keywords

For this example, let's implement the `defer` keyword.

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

Expected output:

```
Entering function...
Doing work...
   [Defer] Executing cleanup 2 (LIFO)
   [Defer] Executing cleanup 1 (LIFO)
```

To implement `defer`, we need to update the Lexer to recognize the keyword, the Parser to handle the new statement, and the Lowering engine to manage a LIFO stack of cleanup fragments.

### 1. Add to the Lexer

Update `%KEYWORDS` in `Brocken::Lexer`:

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

### 2. Update the AST

Add a new AST node class in `Brocken::AST::Stmt`:

```perl
class Brocken::AST::Stmt::Defer : isa(Brocken::AST::Node) {
    field $block : param : reader;
}
```

### 3. Update the Parser

Register the handler in `%STMT_HANDLERS`:

```perl
my %STMT_HANDLERS = (
    # ...
    'defer' => '_parse_defer'
    #...
);
```

Implement the parsing method:

```perl
method _parse_defer() {
    $self->advance(); # Consumes the 'defer' keyword
    my $block = $self->_parse_block_stmt();
    return Brocken::AST::Stmt::Defer->new( block => $block );
}
```

### 4. Update Lowering.pm

Add the defer stack and logic:

```perl
field @defer_stack; # Stack of [ \@instructions ]

method _emit_all_defers() {
    for my $fragment (reverse @defer_stack) {
        $builder->push_instruction($_) for @$fragment;
    }
}

method lower_Defer($node) {
    my @saved_instructions = $builder->instructions;
    $builder->set_instructions();

    $self->lower($node->block);

    my @deferred_instructions = $builder->instructions;
    $builder->set_instructions(@saved_instructions);

    push @defer_stack, \@deferred_instructions;
    return (undef, 'void');
}
```

Update `lower_Return` to trigger defers before returning:

```perl
method lower_Return($node) {
    die "Return outside sub" if $routine_depth == 0;
    my ( $rv, $ty ) = $self->lower( $node->expr );

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
```

Localize the defer stack in each routine handler:

```perl
method lower_Method($node) {
    push @routine_types, 'method';
    my @old_defers = @defer_stack;
    @defer_stack = ();

    # ... existing setup code ...

    $self->lower_block( $node->body->statements );

    $self->_emit_all_defers();
    $builder->emit( 'leave_func', 'void', [0] );

    # ... existing cleanup code ...
    @defer_stack = @old_defers;
    pop @routine_types;
}
```

This pattern applies to `lower_Method`, `lower_ClassDecl`, and `lower_AnonSub`.

---

## Adding an IR Instruction

### 1. Pick a name

No central registry. Use descriptive names like `atomic_add` or `load_field`.

### 2. Emit it from lowering

```perl
$builder->emit( 'my_new_op', 'Int', [ $arg1, $arg2 ] );
```

### 3. Handle it in every target

Add an `elsif` branch to `emit_op` in each `Target::*` module. Every target must handle it.

---

## Adding a Type

Types are just strings: `Int`, `String`, `Any`, `Bool`, `Class`. To add one:

1. Add it to `%KEYWORDS` in the lexer.
2. Update `_parse_type_spec` in `Parser.pm` to recognize it.
3. Handle it in `Lowering.pm`:
   - Variable declarations (unboxed or tagged?)
   - `M_print_any` (new tag case)
   - Binary ops (type checking)
   - GC (does it hold pointers?)
4. If it has literal constants, update `DataSegment`.

---

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

---

## Adding an Optimization

Optimizations go in `lib/Brocken/Compiler/Optimizer.pm`:

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

---

## Adding or Updating the Runtime

The runtime is generated inline during lowering. All runtime functions live in `Lowering.pm` and emit IR that becomes machine code in the same `.text` section as user code.

### Runtime functions

Currently injected runtime functions:

| Function | Purpose |
|----------|---------|
| `M_gc_alloc` | Immix bump allocator (64KB blocks, 128-byte lines) |
| `M_gc_collect` | Root-walk from shadow stacks, mark with cycle detection |
| `M_gc_mark_obj` | Mark objects (arrays, class instances) |
| `M_gc_sweep` | Free unmarked objects, manage line reuse |
| `M_print_int` | Divide-by-10 loop, write digits to stdout |
| `M_print_any` | Tagged variant printer |
| `M_fiber_new` | Allocate FCB, set up stack + shadow stack |
| `M_fiber_switch` | Context switch: save/restore RSP and preserved regs |
| `M_veh_handler` | Windows VEH for stack overflow recovery |
| `M_concat` | String concatenation |
| `M_any_to_str` | Convert Any to String |

### Adding a new runtime function

1. Create a new method in `Lowering.pm` that emits the IR.
2. Call it from `lower_program` during initialization.
3. Register it with the codegen for debug info.

Example: adding a `M_print_string` function:

```perl
method _emit_print_string() {
    my $fn = 'M_print_string';
    $builder->push_label($fn);
    $builder->emit( 'enter_func', 'void', [] );

    my $str_ptr = $builder->emit( 'get_arg', 'ptr', [0] );
    my $str_len = $builder->emit( 'load_mem_disp', 'i64', [ $str_ptr, -8 ] );

    # Write loop...
    $builder->emit( 'leave_func', 'void', [0] );
    $builder->pop_label();
}
```

### Replacing the GC

The GC lives in `M_gc_alloc`, `M_gc_collect`, `M_gc_mark_obj`, and `M_gc_sweep`. To replace it:

1. Understand the current heap layout:
   - 64KB blocks allocated via `intrinsic_alloc`
   - Line bitmap at offset +8 within each block (512 bytes = 4096 lines)
   - User data starts at offset +1024

2. Understand the Isolate control block fields:
   - `heap_ptr`, `heap_limit`, `state_ptr`
   - `current_fcb`, `fiber_head`
   - `heap_base`, `block_cursor`, `block_limit`
   - `free_blocks`, `recyclable_blocks`, `gc_cycle`

3. Replace the allocation and collection functions while maintaining the same IR interface.

4. Ensure shadow stack integration - the GC relies on `shadow_push`/`shadow_pop` to find live pointers.

### GC header format

Objects on the heap have a header:

```
Offset 0: 1 byte flags (bit 0 = leaf bit, bit 1 = marked)
Offset 1: 4 bytes byte_len
Offset 5: 4 bytes char_len (for strings)
Offset 9: data...
```

The leaf bit signals the GC to skip pointer tracing. Objects with pointers (arrays, class instances) have this bit clear.

### Debugging the GC

Use `perl brocken.pl --debug=1` and inspect with GDB:

```bash
gdb --batch -ex "break M_gc_alloc" -ex "run" -ex "bt" -ex "info locals" --args brocken_out.exe
```

The GC cycle counter (`iso_offset('gc_cycle')`) guards against infinite recursion.