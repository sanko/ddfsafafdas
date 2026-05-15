# Brocken Internals

This document covers the internal structure of the Brocken compiler and debugging tips.

For adding new features (keywords, IR instructions, platforms, optimizations, runtime modifications), see [Extending Brocken](extending.md).

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

## Compiler Structure

### Key files

| File | Purpose |
|------|---------|
| `lib/Brocken/Lexer.pm` | Tokenizer |
| `lib/Brocken/Parser.pm` | Pratt parser |
| `lib/Brocken/AST.pm` | AST node types |
| `lib/Brocken/IR.pm` | IR builder |
| `lib/Brocken/Compiler/Lowering.pm` | AST → IR, runtime injection |
| `lib/Brocken/Compiler/Optimizer.pm` | IR transforms |
| `lib/Brocken/Codegen.pm` | Register allocation + instruction dispatch |
| `lib/Brocken/Target/X64.pm` | x64 instruction emission |
| `lib/Brocken/Target/X64/Emit.pm` | x64 encoder |
| `lib/Brocken/Format/PE.pm` | Windows PE writer |
| `lib/Brocken/Format/ELF.pm` | Linux ELF writer |
| `lib/Brocken/Format/DWARF.pm` | DWARF debug info |
| `lib/Brocken/Platform/Windows.pm` | Windows intrinsics |
| `lib/Brocken/Platform/Linux.pm` | Linux intrinsics |

### Lowering.pm structure

The lowering phase is the largest component (~1400 lines). Key sections:

- **Runtime initialization** (lines ~1-150): Isolate setup, GC allocator, runtime functions
- **AST visitors** (lines ~150-900): Lower each node type to IR
- **Local collection** (lines ~900-1100): DWARF variable location tracking
- **Function ranges** (lines ~1100-1300): Debug info for each function

### Data structures

**Isolate control block** (88 bytes, R14-relative):

```perl
iso_offset => {
    heap_ptr           => 0,
    heap_limit         => 8,
    state_ptr          => 16,
    current_fcb        => 24,
    fiber_head         => 32,
    heap_base          => 40,
    block_cursor       => 48,
    block_limit        => 56,
    free_blocks        => 64,
    recyclable_blocks  => 72,
    gc_cycle           => 80,
}
```

**Fiber control block** (56 bytes):

```perl
fcb_offset => {
    sp           => 0,
    stack_base   => 8,
    stack_limit  => 16,
    shadow_base  => 24,
    shadow_ptr   => 32,
    caller       => 40,
    next         => 48,
}
```

### Heap layout

- **Block size**: 64KB (`BLOCK_SIZE = 65536`)
- **Line size**: 128 bytes
- **Lines per block**: 512
- **Line bitmap**: bytes 8-511 of each block (one bit per line)
- **User data**: offset +1024 within each block