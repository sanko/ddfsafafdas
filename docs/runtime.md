# Brocken Runtime System

Brocken doesn't link against a runtime library. The runtime is generated inline during lowering. When you compile a Brocken program, the GC allocator, the fiber context switcher, the integer printer — all of it becomes machine code in the same `.text` section as your code.

## Isolate Control Block

Every OS thread (Isolate) has one control block, allocated at startup. The Isolate pointer lives in register `R14` (x64) for the entire program. It never holds anything else.

Layout, from `Compiler.pm`:

```perl
iso_offset => {
    heap_ptr           => 0,    # Current bump pointer
    heap_limit         => 8,    # End of current GC block
    state_ptr          => 16,   # Runtime flags
    current_fcb        => 24,   # Active Fiber Control Block
    fiber_head         => 32,   # Head of fiber linked list
    heap_base          => 40,   # Entire GC heap base
    block_cursor       => 48,   # Current allocation block
    block_limit        => 56,   # End of current block
    free_blocks        => 64,   # Free block list (singly linked)
    recyclable_blocks  => 72,   # Blocks ready for line reuse
    gc_cycle           => 80,   # Cycle counter
}
```

88 bytes. Accessed via `load_iso_disp` / `store_iso_disp` IR ops, which compile to R14-relative memory loads and stores.

## Fiber Control Block

Each fiber has an FCB — its identity. Holds stack pointer, shadow stack state, and fiber list links.

```perl
fcb_offset => {
    sp           => 0,    # Saved RSP when suspended
    stack_base   => 8,    # Stack allocation base
    stack_limit  => 16,   # Stack end (guard page)
    shadow_base  => 24,   # Shadow stack base
    shadow_ptr   => 32,   # Current shadow stack pointer
    caller       => 40,   # FCB that called transfer()
    next         => 48,   # Next FCB in Isolate's fiber list
}
```

56 bytes.

## Shadow Stack

The shadow stack is how the GC finds live pointers in native code. Without it, the GC would have to conservatively scan the machine stack and guess which values are pointers.

The idea is simple:
- Every local holding a GC-traced reference (Any, Array, class instance, String) gets registered on the shadow stack.
- On function entry, `shadow_get` saves the current shadow stack height.
- Before any allocation (which might trigger GC), `shadow_push` records live references.
- On function exit, `shadow_set` restores the saved height, effectively popping everything.

The shadow stack lives inside the fiber's stack allocation, tracked by `shadow_ptr` in the FCB.

### Where shadow ops are emitted

- **`Any` variable declarations** — `shadow_push` after init
- **Function entry** — `shadow_get` to capture height
- **Function exit** (return or implicit end) — `shadow_set` to restore
- **Method/function calls** — `shadow_push` for the invocant and Any-typed arguments before `call_func`

## Immix GC

Brocken uses an Immix-style mark-region collector. The heap is divided into 32KB blocks, each split into 128-byte lines. This gives better fragmentation behavior than plain mark-sweep without the copying cost of a semi-space collector.

### Allocation (M_gc_alloc)

Bump-pointer within the current line:
1. Check if `heap_ptr + size <= heap_limit`
2. If yes: bump and return
3. If no: try next line in current block
4. If no lines left: call `M_gc_collect`
5. If still no space: `VirtualAlloc`/`mmap` a new block

### Marking (M_gc_mark_obj)

- Bit 0 of the object header is the "leaf bit." If set, the object contains no pointers — skip tracing.
- Arrays: trace all elements.
- Class instances: trace all field slots.
- A visited-set prevents cycles.

### Collection (M_gc_collect)

1. Walk every fiber's shadow stack in this Isolate.
2. Transitively mark from each pointer.
3. Sweep: empty blocks go to `free_blocks`. Partially-empty blocks go to `recyclable_blocks` for line reuse.

### GC header format

```
[1 byte flags][4 bytes byte_len][4 bytes char_len][data...]
```

## Fibers

Stackful coroutines. Each fiber gets its own machine stack and shadow stack. Switching between them is a full context switch — all callee-saved registers are saved and restored.

### Lifecycle

```
Main ──transfer()──→ Fiber ──yield/return──→ Main
                      ▲                       │
                      └─────transfer()────────┘
```

### M_fiber_new

1. Allocate FCB from GC heap.
2. Allocate stack (64KB, VirtualAlloc or mmap).
3. Allocate shadow stack within the same allocation.
4. Set up initial frame with fiber entry as return address.
5. Link FCB into the Isolate's `fiber_head` list.

### M_fiber_switch

On x64:
1. Push all preserved registers (rbx, rsi, rdi, r12-r15, rbp)
2. Save current RSP into caller FCB's `sp`
3. Load target FCB's `sp` into RSP
4. Pop preserved registers from target's stack
5. Return to whatever address is on top of target's stack

### Yield and transfer

- `yield expr`: saves the value, records caller FCB, calls M_fiber_switch back to caller.
- `transfer($fiber, expr)`: saves the argument, calls M_fiber_switch with target FCB.
- A fiber that returns (rather than yielding) switches back to the caller with the return value. It can't be resumed after that.

## Isolates

True OS threads with shared-nothing memory. Still being built out:
- Each Isolate gets its own GC heap, fiber scheduler, data segment.
- Communication through Channels (lock-free ring buffers).
- Complex data is deep-copied across the boundary; primitives go by pointer.

The Isolate control block already has fields for all this per-Isolate state.

## Platform Intrinsics

Each OS provides intrinsic functions, emitted as labeled code during lowering.

### Windows

File: `lib/Brocken/Platform/Windows.pm`

- `VirtualAlloc` — allocate virtual memory
- `WriteFile` — write bytes to a handle
- `GetStdHandle` — get stdout handle
- `ExitProcess` — terminate
- `SetConsoleOutputCP` — UTF-8 console (65001)
- `AddVectoredExceptionHandler` — stack overflow recovery

Uses Windows x64 ABI: args in RCX, RDX, R8, R9; 32 bytes shadow space.

### Linux

File: `lib/Brocken/Platform/Linux.pm`

- `mmap` (syscall 9) — allocate memory
- `write` (syscall 1) — write to fd
- `exit` (syscall 60) — terminate

Uses SysV AMD64 ABI: args in RDI, RSI, RDX, RCX, R8, R9. Syscall clobbers RCX, R11.

## Tagged Variant (Any)

Dynamically typed variables use a 16-byte struct:

```
Offset 0: 8-byte value (raw Int, or pointer to heap data)
Offset 8: 8-byte type tag (0=Int, 1=String, 2=Array, 3=Class)
```

- `M_print_any` dispatches on the tag.
- Binary ops on `Any` vs `Int` do runtime type checks.
- Explicitly typed variables (`my Int $x`) skip the variant entirely and compile to raw register/stack values.

## VTable Dispatch

Classes use virtual method tables:
- Each instance has a VTable pointer (field index -1).
- The VTable is an array of function pointers, one per method.
- `$obj->method(...)` compiles to: load VTable → load function pointer at method index → call through pointer (with object as first arg).

VTables are generated during class lowering: global method counters assign unique indices, `load_data_addr` references entries in the data segment, `new` allocates via GC, zeroes fields, sets the VTable pointer.

## Defer Stack

`defer { ... }` uses a LIFO stack in the lowering phase:
1. On seeing a defer block, save the current instruction stream, lower the body into a temp stream, push the captured instructions onto `@defer_stack`.
2. Restore the main instruction stream.
3. Before any `return` or at function end, `_emit_all_defers()` prepends the deferred instructions in reverse (LIFO) order.
4. The defer stack is localized per function: entering a new function saves and clears it, exiting restores it.
