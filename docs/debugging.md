# Debugging & Debug Information

Brocken can emit rich debug information so you can use standard tools (GDB,
WinDbg, etc.) to step through your compiled Brocken programs at the source
level.

There are two **independent** debug information systems, selected automatically
by the target OS:

| System                          | Format  | Target       | Tools                   |
|----------------------------------|---------|--------------|-------------------------|
| DWARF (`.debug_*` sections)      | DWARF3  | PE + ELF     | GDB, LLDB, readelf      |
| SEH (`.pdata` / `.xdata`)        | PE SEH  | PE (win64)   | GDB, WinDbg, Xperf      |
| `.eh_frame`                      | DWARF   | ELF (linux)   | GDB, perf, libunwind    |

All three can be emitted simultaneously on PE (DWARF + SEH) for maximum
debugger compatibility.

---

## Debug Levels

The `debug` parameter is an integer passed to `Brocken::Compiler->new()`.
It can also be set via the `--debug=N` flag when running `brocken.pl`.

| Level | Effect |
|-------|--------|
| **0** | No debug sections. Lean binary, no source mapping. (Default) |
| **1** | Emit all debug sections (DWARF `.debug_line`, `.debug_info`, `.debug_abbrev`, `.debug_frame`, `.debug_aranges`, `.debug_pubnames`). On win64, also emit SEH `.pdata` / `.xdata` unwind tables. On ELF, also emit `.eh_frame`. Source location tracking is active. |
| **2** | Same as level 1, plus hex dumps of `.debug_info`, `.debug_abbrev`, `.debug_aranges`, `.debug_pubnames`. |
| **4+** | Include class/struct type information in `.debug_info` (DWARF `DW_TAG_structure_type` and `DW_TAG_member` DIEs). |

Usage:

```bash
# Default: no debug info
perl brocken.pl

# Explicit level
perl brocken.pl --debug=1
perl brocken.pl --debug=0    # explicit no debug info
```

---

## Architecture

### Source Location Tracking

During lowering, every source-level IR instruction is annotated with its
original line and column via `push_source_loc` in `Brocken::Compiler`:

```perl
# Compiler.pm
method push_source_loc ($offset, $line, $col) {
    push @source_locs, { offset => $offset, line => $line, col => $col };
}
```

This produces an array of `{ offset, line, col }` hashes that the DWARF
builder consumes to generate `.debug_line` data.

### Function Range Tracking

Every function (named sub, anonymous sub, method, and the implicit main
body) is tracked via `push_func_range` / `close_last_func_range`:

```perl
# Lowering.pm - on function entry
$driver->push_func_range({ name => $name, start => $driver->as->offset });

# Codegen.pm - on function exit  
$driver->close_last_func_range( $driver->as->offset );
```

Each range entry contains:
- `name` - symbol name (e.g. `M_multiply`, `L_MAIN_START`)
- `start` - byte offset in `.text`
- `end` - byte offset in `.text` (set by `close_last_func_range`)
- `ctx_size` - size of register context save area
- `params` - array of `{ name, type, slot }` for parameters
- `locals` - array of `{ name, type, slot }` for local variables

### Plumbing to the Format Layer

After codegen, `brocken.pl` passes the function ranges to the format object
and builds the DWARF sections:

```perl
# brocken.pl
$p->format->set_func_ranges(\@funcs);
$p->format->set_debug_data($dwarf);
```

The `Format.pm` base class stores these in `$func_ranges` and `$debug_data`
hashref. Each format module (PE, ELF) can then read them during `write_bin`.

---

## DWARF Sections

All DWARF sections are built by `Brocken::Format::DWARF`. The constructor
takes:

```perl
my $dw = Brocken::Format::DWARF->new(
    source_locs   => \@sls,       # [ { offset, line, col }, ... ]
    text_base     => $text_base,  # image_base + .text RVA
    func_ranges   => \@funcs,     # [ { name, start, end, ... }, ... ]
    context_size  => 64,          # 64 for win64, 48 for linux
    class_info    => \%class_info, # optional class definitions
    debug         => $dbg,        # control level-conditional output
    eh_frame_base => $eh_frame_base, # image_base + .eh_frame RVA (0 if N/A)
);
```

### `.debug_line` - Line Number Program

Maps machine-code offsets to source lines using a compact state-machine
encoding (DWARF3 line number program).

- **Source**: `build_debug_line()` in DWARF.pm
- **Encoding**: Extended opcodes for address (`0x02` + 8-byte address) and
  line (`0x03` + SLEB128 delta), standard opcodes for end-of-sequence
- **File**: Always `source.brocken` (the inline source from `brocken.pl`)

```
.debug_line layout:
  unit_length | version(2) | prologue_length | prologue | program
```

### `.debug_info` - Compilation Unit & Subprograms

Describes the compilation unit, base types, optional class types (at
debug >= 4), and subprogram entries for every function.

- **Abbreviation codes used**:

| Code | Tag                         | Children | Attrs                                    |
|------|-----------------------------|----------|------------------------------------------|
| 1    | `DW_TAG_compile_unit`        | yes      | stmt_list, name, language                |
| 2    | `DW_TAG_base_type`           | no       | name, byte_size, encoding                |
| 3    | `DW_TAG_subprogram`          | yes      | name, low_pc, high_pc, frame_base        |
| 4    | `DW_TAG_formal_parameter`    | no       | name, location, type                     |
| 5    | `DW_TAG_variable`            | no       | name, location, type                     |
| 6    | `DW_TAG_structure_type`      | yes      | name, byte_size                          |
| 7    | `DW_TAG_member`              | no       | name, data_member_location, type         |
| 8    | `DW_TAG_array_type`          | yes      | type                                     |
| 9    | `DW_TAG_subrange_type`       | no       | count                                    |

- **Base types**: `Int` (5, signed), `Bool` (2), `String` (1), `Any` (1),
  `ptr` (1), `Array` (1). All 8 bytes wide.
- **Frame base**: `DW_OP_breg6(0)` - RBP-relative addressing.
- **Parameter/Location**: `DW_OP_fbreg(N)` - offset from frame base (RBP).

### `.debug_abbrev` - Abbreviation Table

Compact declaration of the DIE tag/attribute layouts used in
`.debug_info`. Currently defines 9 abbreviation codes.

### `.debug_frame` - Call Frame Information (DWARF3)

Describes how to unwind the stack for each function. Used by GDB for
backtraces.

- **CIE**: CFA = RSP + 8, return address saved at CFA - 8
- **FDE per function**: CFA = RBP + `context_size + 8`, each preserved
  register saved at a known offset from CFA

The specific instructions emitted per FDE:

```
DW_CFA_def_cfa: rbp(6), offset=(context_size + 8)
DW_CFA_offset: rbp,  save_off   (for each preserved register)
...
```

Example for win64 (context_size = 64):

```
DW_CFA_def_cfa: rbp(6), +72
DW_CFA_offset: rbp(6),  cfa-8    → saved at CFA-8
DW_CFA_offset: rbx(3),  cfa-16
DW_CFA_offset: rdi(5),  cfa-24
DW_CFA_offset: rsi(4),  cfa-32
DW_CFA_offset: r12(12), cfa-40
DW_CFA_offset: r13(13), cfa-48
DW_CFA_offset: r14(14), cfa-56
DW_CFA_offset: r15(15), cfa-64
```

The prologue is not explicitly advanced past - GDB's prologue skip
heuristic handles the transition from the initial RSP-based CFA to the
RBP-based CFA.

### `.debug_aranges` - Address Range Table

Maps function address ranges for fast debug info lookup. One tuple per
function: `{ start, length }`, terminated by a null entry.

### `.debug_pubnames` - Public Names Index

Maps function names to their DIE offsets in `.debug_info`, for
symbolic lookup.

---

## SEH (Windows PE)

On win64, Brocken emits SEH (Structured Exception Handling) tables so
GDB and Windows itself can unwind through Brocken code.

### `.pdata` - Runtime Function Table

Each function gets one `RUNTIME_FUNCTION` entry (12 bytes).

```c
typedef struct _RUNTIME_FUNCTION {
    ULONG BeginAddress;   // RVA relative to .text start
    ULONG EndAddress;     // RVA relative to .text start (exclusive)
    ULONG UnwindData;     // RVA of UNWIND_INFO in .xdata
} RUNTIME_FUNCTION, *PRUNTIME_FUNCTION;
```

All entries point to a **single shared `UNWIND_INFO`** in `.xdata` because
every Brocken function has an identical prologue on win64.

### `.xdata` - Unwind Info

A single 28-byte `UNWIND_INFO` structure shared across all functions:

```
Version:            1
Flags:              0 (UNW_FLAG_NHANDLER)
SizeOfProlog:       22 bytes
CountOfCodes:       11
FrameRegister:      0 (RBP not encoded as frame register shortcut)
```

Unwind codes (in descending code offset order):

| CodeOffset | Operation           | Info                       |
|------------|---------------------|----------------------------|
| 15         | UWOP_ALLOC_LARGE    | Scaled size = 133 (1064÷8) |
| 12         | UWOP_SET_FPREG      | -                          |
| 10         | UWOP_PUSH_NONVOL    | r15                        |
| 8          | UWOP_PUSH_NONVOL    | r14                        |
| 6          | UWOP_PUSH_NONVOL    | r13                        |
| 4          | UWOP_PUSH_NONVOL    | r12                        |
| 3          | UWOP_PUSH_NONVOL    | rsi                        |
| 2          | UWOP_PUSH_NONVOL    | rdi                        |
| 1          | UWOP_PUSH_NONVOL    | rbx                        |
| 0          | UWOP_PUSH_NONVOL    | rbp                        |

**Why not set `FrameRegister`?** The frame size (1064) isn't evenly
divisible by 16 (1064 ÷ 16 = 66.5), so we can't use the frame-register
shortcut. The unwinder processes the full code list instead, which is
correct.

### Prologue (win64)

The prologue that the SEH tables describe is emitted by `enter_func` in
`Brocken::Target::X64`:

```asm
push rbp        ; 1 byte   offset 0
push rbx        ; 1 byte   offset 1
push rdi        ; 1 byte   offset 2
push rsi        ; 1 byte   offset 3
push r12        ; 2 bytes  offset 4
push r13        ; 2 bytes  offset 6
push r14        ; 2 bytes  offset 8
push r15        ; 2 bytes  offset 10
mov rbp, rsp    ; 3 bytes  offset 12
sub rsp, 1064   ; 7 bytes  offset 15
                ;          offset 22 = end of prologue
```

Total: 22 bytes, matching `SizeOfProlog`.

---

## `.eh_frame` (Linux ELF)

On Linux, Brocken emits `.eh_frame` - an ELF-specific variant of DWARF
call frame information that GDB, `perf`, and `libunwind` all consume.

### CIE

```c
Version:            1 (not 3 - .eh_frame uses version 1)
Augmentation:       "zR"
FDE encoding:       DW_EH_PE_pcrel | DW_EH_PE_sdata4 (0x1B)
Code alignment:     1
Data alignment:     -8
Return address:     16
Initial state:      CFA = RSP + 8
                    RA  = CFA - 8
```

The "zR" augmentation tells consumers the FDE addresses are
position-independent (PC-relative), which is essential for shared
libraries and ASLR.

### FDE

Each function gets one FDE. The address fields use PC-relative encoding
so the section is fully relocatable.

```
initial_location:  .text_base + fn_start - (eh_frame_section + FDE_offset + 8)
address_range:     fn_end - fn_start
```

The same DW_CFA instructions from `.debug_frame` follow, describing the
RBP-based CFA and register save slots.

### Why both `.debug_frame` and `.eh_frame`?

| Section        | Kept by `strip` | Used by        |
|----------------|-----------------|----------------|
| `.debug_frame` | No (debug section)    | GDB (if present) |
| `.eh_frame`    | Yes (non-debug, ALLOC) | GDB, perf, libunwind, Linux kernel |

`.debug_frame` is more complete (DWARF3) but gets stripped from release
builds. `.eh_frame` survives stripping and is the standard unwind
information format on Linux.

---

## Section Layout

### PE (Windows) - with debug

```
.text       RX   code
.data       RW   data + BSS
.idata      RW   import directory
.debug_line      source line mapping
.debug_info      DIE tree
.debug_abbrev    abbreviation table
.debug_frame     DWARF CFI
.debug_aranges   address ranges
.debug_pubnames  public names
.pdata           SEH function table  (win64 only)
.xdata           SEH unwind info     (win64 only)
```

### ELF (Linux) - with debug

```
.text   RX      code
.data   RW      data + BSS
.debug_line     source line mapping
.debug_info     DIE tree
.debug_abbrev   abbreviation table
.debug_frame    DWARF CFI
.eh_frame       position-independent CFI
```

---

## GDB Usage

### Linux

```bash
# Build with debug info (debug >= 1 or --debug=1)
perl brocken.pl --debug=1

# GDB with source-level breakpoints
gdb --batch \
  -ex "break source.brocken:9" \
  -ex "run" \
  -ex "bt" \
  -ex "info locals" \
  -ex "quit" \
  --args ./brocken_out

# Or step through with the TUI
gdb -tui \
  -ex "break source.brocken:9" \
  -ex "run" \
  ./brocken_out
```

### Windows (PE)

On Windows, GDB can use either `.debug_frame` (DWARF) or `.pdata`/`.xdata`
(SEH) for backtracing.

```bash
# GDB can read SEH unwind tables for stack unwinding
gdb --batch \
  -ex "break *0x140001000" \       # break at .text entry
  -ex "run" \
  -ex "bt" \
  -ex "quit" \
  --args brocken_out.exe
```

**Known limitations:**
- PE/COFF section names are truncated to 8 characters. GDB can't
  auto-discover `.debug_frame` by name on PE (COFF string table is
  not supported). `.pdata`/`.xdata` are the reliable unwind path.
- Source-level breakpoints (`break source.brocken:N`) work when GDB
  can read `.debug_line` - if the section name wasn't truncated.
  The section is registered as `.debug_line` (exactly 8 chars + null),
  so it should work with GDB.

### Platform intrinsics

Brocken's debug output also shows function ranges with their metadata:

```
  M_multiply    start=0x0DA2 end=0x0E4D ctx=64 params=$val:Int,$factor:Int
  M_User::set_id  start=0x0EA8 end=0x0EF6 ctx=64 params=$self:ptr,$val:Int
```

Combine this with `.debug_aranges` output to set breakpoints by
function:

```bash
gdb -ex "break *0x$((0x140000000 + 0x0DA2))" -ex "run" ./brocken_out.exe
```

---

## Configuration Reference

### `Brocken::Compiler` - `debug` parameter

```perl
my $p = Brocken::Compiler->new( debug => $debug_level );
```

| Value | Behavior |
|-------|----------|
| 0     | No debug sections in output binary |
| ≥1    | Enable all debug sections + GDB launch |
| ≥4    | Include class/struct type DIEs in `.debug_info` |

### CLI flag

```
perl brocken.pl --debug=2
```

Read from `@ARGV` in `brocken.pl`:
```perl
my $dbg = 3;
for (@ARGV) { $dbg = $1 if /^--debug=(\d+)$/; }
```

### Format-level configuration

Each format module checks the debug level in `_setup_layout`:

```perl
# ELF.pm - registers debug sections only when $dbg >= 1
if ($dbg >= 1) {
    $l->add_section( '.debug_line',   4096, 0 );
    $l->add_section( '.eh_frame',     4096, 0 );
    ...
}

# PE.pm - also adds SEH sections on win64
if ($dbg >= 1) {
    ...
    if ($o eq 'win64') {
        $l->add_section( '.pdata', 4096, 0x42000040 );
        $l->add_section( '.xdata', 4096, 0x42000040 );
    }
}
```

### DWARF module configuration

The `Brocken::Format::DWARF` object is configured by `brocken.pl`:

```perl
my $dw = Brocken::Format::DWARF->new(
    source_locs   => \@sls,
    text_base     => $p->format->image_base + $p->format->rva_for('.text'),
    eh_frame_base => eval { $p->format->image_base + $p->format->rva_for('.eh_frame') } // 0,
    func_ranges   => \@funcs,
    context_size  => $p->context_size,
    class_info    => \%class_info,
    debug         => $p->debug,
);
```

- `eh_frame_base` is computed via `eval` - gracefully degrades to 0 on
  targets that don't have an `.eh_frame` section (e.g. PE).
- `class_info` is only populated from the lowering phase and only affects
  output at debug ≥ 4.

---

## Data Directory Entries (PE)

The PE optional header's data directory array (16 entries) is laid out as
follows when debug ≥ 1:

| Index | Entry            | Contents                        |
|-------|------------------|---------------------------------|
| 0     | Export           | 0 (not used)                    |
| 1     | Import           | Points to `.idata` + 256        |
| 2     | Resource         | 0                               |
| 3     | Exception        | Points to `.pdata` (SEH)        |
| 4-11  | (reserved)       | 0                               |
| 12    | IAT              | Points to `.idata` base         |
| 13-15 | (reserved)       | 0                               |

The Exception entry (DD[3]) is only valid when `$os eq 'win64'` and
`$pdata_size > 0`.

---

## Future Work

- **CodeView / PDB** - Full Windows PDB support for Visual Studio / WinDbg
  source-level debugging. Currently deferred; SEH covers the backtrace
  requirement.
- **`eh_frame_hdr`** - Standard `.eh_frame_hdr` section for fast
  binary-search unwinding. Not needed for GDB but useful for `perf`.
- **`debug_types`** - Type information is currently embedded inline in
  `.debug_info`. Moving to `.debug_types` would reduce CU size for
  repeated types.
- **Line-number prologue** - Adding `DW_CFA_advance_loc` to the FDE
  instructions would precisely describe when the prologue transitions
  from RSP-relative to RBP-relative CFA. Currently GDB's heuristic
  handles this well enough.
