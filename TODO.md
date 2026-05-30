# Current task list:

We wrote a compiler in pure perl. Implement the following features:

 - [x] __LINE__, __FILE__
 - [x] Add the ability to handle `#line` directives like perl, C, etc.
 - [x] Enhance our Immix implementation with a nursery for short lived allocations. (Implemented Generational Semi-Space Evacuating GC).
 - [x] Implement `our` for package level globals.
 - [x] `ddx` / `dd` keywords: `ddx` prints pretty-printed value to STDERR, `dd` returns stringified
 - [x] `...` yada-yada stub from Perl
 - [ ] Implement these loop keywords (they should behave exactly as they do in perl 5.40):
     - [x] `next`
     - [x] `last`
     - [x] `redo`
     - [ ] `for` loop. (Basic Array iteration is done, but needs Range, Hash, and Destructuring support). All of these examples should work:
         ```perl
            for (@ary) { s/foo/bar/ }

            for my $elem (@elements) {
                $elem *= 2;
            }

            for $count (reverse(1..10), "BOOM") {
                print $count, "\n";
                sleep(1);
            }

            for (1..15) { print "Merry Christmas\n"; }

            for $item ('a', 'b', 'c') {
                print "Item: $item\n";
            }

            for my ($foo, $bar, $baz) (@list) {
                # do something three-at-a-time
            }

            for my ($key, $value) (%hash) {
                # iterate over the hash
                # The hash is immediately copied to a flat list before the loop
                # starts. The list contains copies of keys but aliases of values.
                # This is the same behaviour as for $var (%hash) {...}
            }
         ```

## Technical Review Findings

Issues discovered during codebase audit (2026-05-29):

### Parser: Implicit return fragility (4 sites)
`Parser.pm` methods `_parse_num_literal` (L642), `_parse_string_literal` (L647), `_parse_bool_literal` (L688), and `_parse_var_ref` (L704) rely on Perl's implicit last-expression return. If anyone adds a statement (e.g., `$self->advance()`) after the `->new(...)` call, these silently return `undef` instead of an AST node, breaking compilation silently.

**Fix**: Add explicit `return` to all four methods.

### Parser: No error recovery
Any parse error calls `die` immediately. There is no mechanism to skip tokens, report multiple errors, or recover to a known state. This makes the compiler unusable for IDE integration and batch-processing malformed files.

### Lexer: Regex performance risk
The main identifier regex `[\$@%]?[\p{L}\p{S}_][\p{L}\p{S}\p{N}_]*` (L113) uses Unicode property classes in backtracking context. Combined with the string interpolation regex on L60 (alternation + `/s`), malformed input can trigger catastrophic backtracking.

**Severity**: Low for valid code, high for fuzz inputs.

### Lexer: `__FILE__` / `__LINE__` match ordering dependency
The `__LINE__`/`__FILE__` check (L106) must appear before the generic identifier match (L113). This ordering dependency is not documented. Adding a new compile-time token that starts with `_` could silently break if placed after the identifier rule.

### DataSegment: Zero-length string edge case
`DataSegment::add_string` now guards against `undef`, but zero-length strings get a GC header with `byte_len=0, char_len=0`. The runtime's string operations (comparison, interpolation, hashing) may not handle zero-length objects correctly in all paths.

### FFI: Pointer heuristic misidentification
`Lowering.pm:669` uses bit-0 tagging to distinguish SMIs from pointers: *"For simplicity in FFI, let's assume if bit 0 is 0 and it's not NULL, it might be a box."* This heuristic will misidentify aligned heap pointers (which naturally have bit 0 clear) as Brocken boxed values when they're actually opaque C pointers returned from FFI calls.

### GC: Write barrier coverage gaps
The write barrier in `Lowering.pm` emits retain/release on array-element assignment, but may not be consistently applied across all mutation paths: hash stores, field assignments via `->`, and `splice`/`push` operations. The `gc_refcnt.t` test was originally written expecting no write barrier, suggesting incomplete coverage.

### Coverage: Probe-line mapping fragility
`Compiler.pm:236-241` reverses the instruction list and scans for `source_loc` ops to map coverage probes to source lines. If any optimization pass reorders, duplicates, or eliminates `source_loc` instructions, the mapping breaks silently — wrong lines get blamed or probes go unmatched.

### X64 target: Uninitialized value warnings
`Target/X64.pm:287` uses `$src` in pattern match without checking it's defined. `Target/X64.pm:591` uses `$imm` in `pack` without a defined check. These fire warnings during normal compilation of certain IR patterns.

### Key Perl syntax features not yet supported
- `given`/`when` (smartmatch)
- Regex literals (`m//`, `s///`, `qr//`)
- `grep` and `sort` builtins
- `pack`/`unpack`
- `map` in expression context (only statement context exists)
- `do BLOCK` expressions
- `eval BLOCK` (only `eval EXPR` exists)
- Format declarations (`format`/`write`)
- `local` scoping and `tie`

---

## CFG-Based Parser Architecture

### Motivation
The current pipeline (Lexer → Pratt Parser → AST → Lowering → flat IR) works but limits optimization and makes context-sensitive parsing difficult. A CFG (Control Flow Graph) as the primary IR between parsing and codegen enables SSA form, better register allocation, selective inlining, and easier extension for features beyond traditional Perl syntax.

### Compiler Flag: `--parser pratt | cfg`
Add a flag to `Compiler.pm` (and eventually to the `bkn` CLI) that selects between two front-ends:

```
compile_source(source, output, filename, parser => 'pratt' | 'cfg')
```

Both paths share the same Lexer, Codegen, and runtime. The flag selects which lowering path to use:
- **`pratt`**: Existing pipeline (Lexer → Parser → AST → Lowering → flat IR)
- **`cfg`**: New pipeline (Lexer → CFGParser → CFG → Lowering → flat IR)

This keeps the existing parser as a fallback while the CFG parser matures. The CFG lowering produces the same IR instructions that Codegen consumes, so no changes are needed downstream.

### CFG Design Layout

```
 Lexer Tokens
      │
      ▼
 CFG Parser ──► BasicBlock[0] ◄── BasicBlock[1] ◄── BasicBlock[N]
                   │                  │                   │
                   ▼                  ▼                   ▼
              Instruction[]      Instruction[]       Instruction[]
               (3-address)        (3-address)         (3-address)
                   │                  │                   │
                   ▼                  ▼                   ▼
              Terminator          Terminator           Terminator
              (br/cond/jmp)       (br/cond/jmp)        (ret/unreachable)
                   │
                   ▼
        CFG Optimizer (dominator tree, SSA construction)
                   │
                   ▼
        Lowering to flat IR (same IR instructions as today)
                   │
                   ▼
              Codegen (unchanged)
```

**Core data structures**:

```perl
class BasicBlock {
    field $id        :reader;       # unique block ID
    field $insts     :reader = [];  # array of IR instructions (3-address)
    field $terminator :reader;      # 'br', 'br_cond', 'ret', 'unreachable'
    field $targets   :reader = [];  # successor BasicBlock IDs
    field $preds     :reader = [];  # predecessor BasicBlock IDs

    # SSA (built after initial parse)
    field $phi_nodes  :reader = [];  # phi instructions at block entry
    field $dom_parent :reader;       # immediate dominator
    field $dom_children :reader = [];
    field $loop_depth :reader = 0;
}
```

**CFG Parser stages**:

1. **Scan phase**: Walk tokens forward, identify control-flow boundaries (`if`/`else`/`while`/`for`/`try`/`defer`). Emit blocks with placeholder terminators.
2. **Fill phase**: Walk each block and emit three-address instructions for expressions and statements.
3. **Resolve phase**: Patch block references (e.g., `if` true-branch target, `while` loop header, exception handler blocks).
4. **SSA construction**: Place phi nodes and rename variables using a dominance frontier pass.

### Difficulty: Adding new keywords/features

| Feature | Current Pratt difficulty | CFG difficulty | Notes |
|---------|------------------------|---------------|-------|
| `given`/`when` | Medium | Easy | CFG already has switch-like block structure; just add smartmatch dispatch |
| Regex literals | Hard | Medium | Need lexer changes; CFG simplifies interpolation parsing |
| `grep` | Medium | Easy | CFG block for iteration is already in place |
| `pack`/`unpack` | Medium | Medium | Builtin call; just needs type expression parsing |
| `do BLOCK` | Easy | Trivial | CFG naturally represents block scopes |
| `eval BLOCK` | Easy | Easy | Catch block in CFG exception table |

**Current Pratt parser**: Adding a keyword requires (a) lexer token, (b) `%STMT_HANDLERS` or `%PREFIX_HANDLERS` entry, (c) parse method. Context-sensitive constructs (like `given`'s smartmatch) require lookahead or speculative parsing. Moderate effort per keyword.

**CFG parser**: Adding a keyword requires (a) lexer token, (b) handler that creates blocks and emits instructions. The block structure is already designed to represent loops, branches, and exception regions. Easier for control-flow keywords. Roughly same effort for expression-level constructs.

### Difficulty: Features beyond Perl's syntax

The CFG approach is naturally more extensible for non-Perl syntax since the parser produces a graph rather than mapping to Perl's statement/expression dichotomy:

| Feature | Difficulty | CFG advantage |
|---------|-----------|---------------|
| Pattern matching (`match`/`case`) | Medium | CFG can emit decision trees as nested blocks; jump threading eliminates intermediates |
| Algebraic data types | Hard | Need type system changes; CFG lowering is unchanged |
| `defer` (exists) | Easy | Already implemented; CFG naturally places cleanup in exit edges |
| Linear types / ownership | Hard | Requires type system; CFG makes move analysis more tractable |
| Effect handlers | Very Hard | CFG with delimited continuations; requires stack frame cloning |
| SIMD vector annotations | Medium | Block-level annotations (like `#[simd]`) attached to loop headers |
| WASM backend | Hard | CFG to WASM is more direct than flat IR to WASM |

**Key insight**: The CFG parser's block-based structure means **control flow is a first-class concept**. Pratt parser produces a tree; lowering then interprets control flow from AST nodes. The CFG parses directly into the structure that the optimizer and codegen need. Adding `break`/`continue` with labels, `switch` chains, or `goto` is trivial in a CFG — each label maps to a block ID, and branches resolve immediately.

### Migration plan

1. **[This sprint]** Define the `BasicBlock` class and `CFG` container in `lib/Brocken/Compiler/CFG.pm`.
2. **[This sprint]** Implement the `--parser` flag in `Compiler.pm` that selects between `pratt` and `cfg`.
3. **[This sprint]** Build a minimal CFG parser that handles `say`, `my`, `if`/`else`, `while` loops — enough to pass the end-to-end tests.
   - [x] `say "string"`, `say "a"; say "b"` (string output)
   - [x] `my Int $x = 3;` (variable declaration with slot allocation)
   - [x] `$x = expr` (assignment expression)
   - [x] `if (cond) { ... } else { ... }` (if/else with proper block terminators)
   - [x] `while (cond) { ... }` (while loop with header/body/end blocks)
   - [x] Numeric/string constants in expressions
   - [x] Basic arithmetic (+, -, *, /)
   - [ ] Integer `say` (needs `M_print_any` / `M_print_int` runtime emission in CFGLowering)
   - [ ] Comparison operators (==, <, >)
   - [ ] `for`, `last`, `next`, `redo`
   - [ ] String interpolation
   - [ ] Subroutines, classes, FFI
4. **[Ongoing]** Port existing Pratt handlers one-by-one to the CFG parser, starting with expressions, then statements.
5. **[Future]** Deprecate and remove the Pratt parser once the CFG parser covers all tests and passes fuzzing.

# Language Milestones & TODO

## Milestone 0: The Binary Foundation
- [x] Lexer, Parser, and AST Generation.
  - [x] SSA IR Builder and Liveness Analysis.
- [x] Register Allocation (Linear Scan / Graph Coloring).
- [x] Pure Perl machine code emitters.
  - [x] Register allocation and basic IR optimization.
  - [x] PE64 (Windows) Formatter.
  - [x] ELF64 (Linux) Formatter.
  - [x] Mach-O (macOS) Formatter.
  - [x] Position Independent Code (ASLR support).
  - [x] Basic System Calls / WinAPI Imports.
  - [x] Automated Layout Manager (Section & Offset tracking).
  - [x] DWARF/SEH debug info generation.
  - [ ] Wasm
- [ ] The `bkn` (bacon) CLI: TOML manifests, Git dependencies, and reproducible builds.

## Milestone 1: The IR & Optimizer Pipeline
- [x] Futhark-style map merging (Loop Fusion).
- [x] Tail call & Leaf optimizations.
- [ ] Inlining pass (inline small functions to eliminate call overhead).
- [x] Constant Folding & Dead Code Elimination (DCE).
- [ ] Arithmetic expansion (IMUL, DIV, SSE/AVX for floats).

## Milestone 2: Memory & The "Variant" Type
- [x] Variant Types: Implement the 16-byte `Any` struct (Tag + Payload) for gradual typing.
- [x] The Shadow Stack: IR instructions to push/pop pointers for the GC.
- [x] The Allocator: Bump-pointer allocation in a pre-allocated `.data` or `mmap` arena.
- [x] Generational Semi-Space GC: Replaced the basic Mark-Region stub with a high-performance minor nursery and major evacuating collector.
- [x] Smart Strings: UTF-8 strings with the O(1) offset-map header.
- [x] Defined-OR: Implement the `//` operator in Parser/Lowering.
- [x] First class `undef`. Formalize `undef` as a distinct type/singleton rather than just a raw `0` pointer, enabling strict type checks and safer `//` evaluation.

## Milestone 3: Data Structures (The "Perl" Experience)
- [x] Arrays: Heap-allocated contiguous memory with bounds checking.
- [x] String Ops: Implement `eq`, `ne`, `lt`, `gt` using string-byte comparison.
- [x] Tuples: Immutable, fixed-size structures (candidates for stack allocation).
- [x] Hashes & Indexing: Hash allocation and dynamic lookup. Built-in DJB2 or MurmurHash implementation
- [x] Hash Keywords: Implement built-in IR calls for...
  - [x] `keys(%h)`
  - [x] `values(%h)`
  - [x] `exists $h{k}`
  - [x] `delete $h{k}`
- [x] Core Globals: Map `@ARGV`, `%ENV`, and `$_` to fixed Isolate State indices. Write runtime startup hooks to populate them from the OS.
- [x] Standard I/O Handles: Expose `STDIN`, `STDOUT`, and `STDERR` as globally available `FileHandle` objects mapped to fd 0, 1, and 2.
- [x] Classes & User-Defined Types: `class`, method dispatch, inheritance, roles, type aliasing.

## Milestone 4: Advanced Runtime (Concurrency)
- [x] Fibers: Context switching by saving/restoring `rsp`/`sp` and registers.
- [ ] Isolates (OS Threads): Wrapping `CreateThread` (Win) and `clone`/`pthread` (Linux).
- [x] Windows TEB (Thread Environment Block) security mitigations.
- [ ] Channels: Lock-free ring buffers for Isolate-to-Isolate communication.

## Milestone 5: JIT-Powered FFI
- [ ] Symbol lookup: Implement pure-Perl manual Export Directory parsing for PE/ELF.
- [x] Stabilize shared library output (.dll/.so): Handled Entry Points and PE SEH metadata.
- [x] Type System: Implemented Brocken::Type mirroring Affix types.
- [x] Compiler/IR: `call_native` IR op and lowering logic exists.
- [x] Reverse trampolines: Safe ABI boundaries for Host-to-Guest callback execution.

## Milestone 6: Developer Experience & Correctness
- [x] Exception Stack Traces: Tie `M_unwind` into the DWARF line-tables to produce human-readable traces mapping `rip` to `source_locs`.
- [ ] Compiler Test Suite and Fuzzing: Expand tests to stress-test the Register Allocator.
- [ ] IR-Diff Tool: Utility to verify output consistency between compiler versions.
- [ ] LSP Stub: Basic IDE support for symbol definitions and type tooltips using POD6.

## Milestone 7: Ecosystem & Security (The Sandboxed Eval)
- [ ] FFI (`Affix`): Declarative C-ABI bindings using opaque pointers.
- [ ] PCRE-compatible Regex engine compiled directly to machine code.
- [ ] Software-Defined MMU & Sandboxing:
  - [ ] Context Isolation: Pin the Isolate struct to a global register.
  - [ ] Fuel System: Inject decrement/check instructions on loop backedges.
  - [ ] Memory Guarding: Check Isolate byte-limits before OS/GC allocations.

## Milestone 8: Advanced Optimizations & GC
- [ ] Escape Analysis & Allocation Swap: Trace object lifetimes in the Optimizer. If an object never escapes its local function, swap `call M_gc_alloc` for a fast `sub rsp, size` stack allocation to eliminate GC overhead.
- [x] Generational GC (The Nursery): Implemented a 64KB nursery for fast bumps and a 2MB dual semi-space for tenured promotions.

## Milestone 9: Distributed Runtime & M:N Scheduling (Long Term)
- [ ] Work-Stealing Scheduler: Map thousands of lightweight Fibers dynamically onto a pool of OS Isolates.
  - API Draft: `spawn { ... }` (creates a scheduled fiber), `yield`, and `await`.
  - Documented Complexities:
    1. Lock-free Work Stealing Deques (managing the ABA problem).
    2. Stop-The-World (STW) pauses across multiple Isolates for global GC sweeps.
    3. Cross-Isolate Memory Barriers (ensuring thread A can see an object written by thread B before GC marks it).

## Milestone 10: Hardware Acceleration & HPC (High-Performance Computing)
- [ ] Dynamic OS Linker: Refactor `PE.pm`/`ELF.pm` to accept a dynamic list of imports.
- [ ] Processor Topology & Affinity: P/E-core scheduling (Alder Lake / Apple Silicon).
- [ ] The GPGPU Backend: Emit PTX (NVIDIA) and SPIR-V (Vulkan/OpenCL).
- [ ] NPU & Tensor Pipeline: Targeting AI Accelerators (AMX, Hexagon).
- [ ] Vectorization (SIMD): Auto-vectorizer mapping IR loops to AVX-512 / ARM Neon.


## Milestone 50: Public
- [ ] Decide on a project name:
     - Brocken (compiler executable is `bkn` pronounced bacon, name based on brocken spectre which kinda looks like a giant pearl)
     - Kaizen (???)
