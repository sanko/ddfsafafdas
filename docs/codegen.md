# Code Generation and Backends

Three layers:

- `Brocken::Codegen` - register allocator + instruction dispatcher
- `Brocken::Target::X64` - maps IR opcodes to x64 machine code
- `Brocken::Target::X64::Emit` - low-level encoder (REX, ModR/M, immediates, fixups)

## Complete IR Instruction Set

Each instruction is `{ op, type, dest, args }`. No central registry - opcodes are just strings.

### Control flow

`label` - code location marker. Uses `name` key, not `args`.

`jmp` - unconditional jump. `target` is a label name.

`cond_br` - conditional branch. `reg` = boolean vreg, `true_l`/`false_l` = label names.

`enter_func` - prologue: push preserved regs, set rbp, allocate local frame.

`leave_func` - epilogue: write return value to rax, restore preserved regs, ret.

### Arithmetic / logic

`constant` - load immediate. Args: `[value]`.

`mov` - copy vreg or immediate. Args: `[source_vreg_or_imm]`.

`add`, `sub`, `mul` - integer math. Args: `[left, right]`.

`div`, `mod` - division, modulo. Args: `[dividend, divisor]`.

`cmp_eq`, `cmp_ne`, `cmp_lt`, `cmp_gt`, `cmp_le`, `cmp_ge` - comparison, result 0 or 1.

`and`, `or`, `xor` - bitwise.

`shl`, `shr` - shifts.

### Memory

`local_load` / `local_store` - local stack slot. Arg: slot number.

`load_mem_disp` / `store_mem_disp` - memory at `base + disp`. Args: `[base_vreg, disp]` (+ value for store).

`load_mem_byte` / `store_mem_byte` - single byte at `base + index`.

### Function calls

`call_func` - call labeled function. Args: `[label, arg1, arg2, ...]`. Return value in rax → dest.

`call_reg` - call function pointer in register. Args: `[vreg, arg1, ...]`.

`get_arg` - read argument from ABI register. Args: `[arg_index]`.

### GC / shadow stack

`shadow_push` - push GC-traced value. Args: `[value_vreg]`.

`shadow_get` - read shadow stack pointer.

`shadow_set` - restore shadow stack pointer. Args: `[saved_ptr]`.

### Isolate

`load_iso_disp` / `store_iso_disp` - read/write Isolate control block field. Args: `[offset_name]` (+ value for store).

`set_isolate_ctx` / `get_isolate_ctx` - set/read R14 (x64).

`get_sp` - read stack pointer. For fiber stack setup.

### Addressing / data

`load_func_addr` - get function label address (VTables, callbacks). Args: `[label_name_or_offset]`.

`load_data_addr` - get data segment entry address (string constants). Args: `[data_offset]`.

`map_op` - fused map loop (currently returns 1).

`intrinsic_*` - delegated to `Platform::emit_intrinsic` for OS-specific ops.

## Register Allocator

File: `lib/Brocken/Codegen.pm`

Linear scan. Straightforward for straight-line IR.

### Liveness

For each vreg (`%N`), find the first and last instruction where it appears. That's its live range.

### Allocation

1. Sort vregs by live range start.
2. Keep an "active" list (vreg → physical register → end position).
3. When a range ends, free the register.
4. When no free register: spill the vreg with the furthest end point to a local slot (`local_load`/`local_store`).
5. Loop until no more spills (usually 2-3 iterations).

The register pool is intentionally limited to callee-saved registers:

```perl
# Windows x64 (6 registers):
rbx, rsi, rdi, r12, r13, r15
# SysV x64 (4 registers):
rbx, r12, r13, r15
```

Volatile registers (rax, rcx, rdx, r8-r11) are excluded - function calls destroy them.

## x64 Target

File: `lib/Brocken/Target/X64.pm` (199 lines)

Dispatch table for IR ops:

```perl
if    ($op eq 'jmp')          { $as->jmp($inst->{target}); }
elsif ($op eq 'cond_br')      { ... test + jcc + jmp ... }
elsif ($op eq 'constant')     { $as->mov_imm($d_reg, $value); }
elsif ($op eq 'add')          { mov_reg + add_reg }
elsif ($op eq 'div')          { cqo + idiv }
elsif ($op eq 'cmp_eq')       { cmp + mov 0 + setcc }
elsif ($op eq 'enter_func')   { push preserved; mov rbp, rsp; sub rsp, frame }
elsif ($op eq 'call_func')    { load args to ABI regs; call; mov rax to dest }
...
```

### x64 Emitter

File: `lib/Brocken/Target/X64/Emit.pm` (225 lines)

Lowest layer. Packs bytes.

**REX prefixes**: Needed for extended registers (r8-r15) and 64-bit operand size.

```perl
method _rex( $w, $r, $x, $b ) {
    my $rex = 0x40;
    $rex |= 0x08 if $w;        # 64-bit
    $rex |= 0x04 if $ri >= 8;  # r/m extension
    $rex |= 0x02 if $xi >= 8;  # index extension
    $rex |= 0x01 if $bi >= 8;  # base extension
}
```

**ModR/M bytes**: Encode addressing mode and operands for memory-referencing instructions.

```perl
my $mod = ($disp == 0 && ($bi & 7) != 5) ? 0
        : ($disp >= -128 && $disp <= 127) ? 1 : 2;
$code .= $self->_rex($w, $ri, 0, $bi)
       . $prefix
       . pack('C', $opcode)
       . pack('C', ($mod << 6) | (($ri & 7) << 3) | ($bi & 7));
$code .= pack('C', 0x24) if (($bi & 7) == 4);  # SIB
$code .= pack('c', $disp)  if $mod == 1;        # 8-bit displacement
$code .= pack('l<', $disp) if $mod == 2;        # 32-bit displacement
```

### Key emitter methods

`mov_reg($d, $s)` - MOV r/m64, r64: REX.W + 0x89 + ModR/M.

`mov_imm($r, $imm)` - MOV r64, imm64: REX.W + 0xB8+reg + 8-byte immediate.

`push_reg` / `pop_reg` - with REX for r8-r15.

`add_reg` / `sub_reg` - REX.W + 0x01/0x29 + ModR/M.

`jmp($label)` / `jcc($cc, $label)` / `call_label($label)` - emit with fixup entries for later patching.

`load_reg_mem($d, $base, $disp)` - MOV r64, [base+disp]: REX.W + 0x8B + ModR/M.

`store_mem_disp_reg($base, $disp, $src)` - MOV [base+disp], r64: REX.W + 0x89 + ModR/M.

`lea_rva($d, $target, $text_base)` - LEA r64, [rip+disp32]. Creates fixup if label isn't defined yet.

`setcc($cc, $d)` - SETcc r/m8: 0x0F + 0x90+cc + ModR/M.

`append_code($bin)` - raw bytes (e.g. CQO = 0x48 0x99).

`mark_label($name)` - record current offset, resolve pending fixups.

`resolve()` - patch all fixups. Offset = `target - current_pos - 4` (RIP-relative).

## ARM64 Target

File: `lib/Brocken/Target/ARM64/Emit.pm` (150 lines)

Skeleton. Not wired into the full pipeline yet (throws "pending refactor"). Has basic A64 encodings:

`mov_reg($d, $s)` - MOV Xd, Xm: 0xAA000000 | (rm << 16) | rd.

`mov_imm($r, $imm)` - MOVZ/MOVK sequence, up to 4 instructions.

`add_imm($r, $imm)` - ADD Xd, Xd, #imm: 12-bit unsigned + optional 12-bit shift.

`load_reg_mem($d, $base, $disp)` - LDR Xd, [Xn, #imm]: scaled 12-bit offset.

`store_mem_disp_reg($base, $disp, $src)` - STR Xn, [Xm, #imm].

`b($label)` / `bl($label)` - 28-bit signed PC-relative offset.

`adrp($r, $target)` - page-relative addressing.

## Binary Format Emitters

### PE (Windows)

File: `lib/Brocken/Format/PE.pm` (92 lines)

Builds a Windows PE64:
- DOS header (MZ + offset to PE)
- NT headers (COFF: 0x8664 for x64, 0xAA64 for ARM64; PE32+ optional header)
- Section table (.text, .data, .idata)
- Import directory for kernel32.dll: ExitProcess, GetStdHandle, WriteFile, VirtualAlloc, SetConsoleOutputCP, AddVectoredExceptionHandler

### ELF (Linux)

File: `lib/Brocken/Format/ELF.pm` (52 lines)

Builds a Linux ELF64:
- ELF header (EM_X86_64, 2 program headers)
- PT_LOAD for .text (RX, paged at 0x1000)
- PT_LOAD for .data (RW, paged after text)

### Layout Calculator

File: `lib/Brocken/Format/Layout.pm` (37 lines)

Computes file offsets and RVAs for each section. Takes estimated sizes from lowering, aligns to page boundaries (0x1000). Exposes `rva_for($name)` and `import_rva($name)`.

## Adding a New Architecture

1. Create `lib/Brocken/Target/ARCH.pm` - subclass `Brocken::Target`, implement `emit_op` and `compile_intrinsic` for every IR opcode.
2. Create `lib/Brocken/Target/ARCH/Emit.pm` - encode every instruction format: register moves, arithmetic, memory, control flow, labels, fixups.
3. Add detection in `Brocken::Compiler::ADJUST`.
4. Define ABI: preserved registers, argument registers, frame layout.
5. If the arch needs a different binary format, update Format modules.
