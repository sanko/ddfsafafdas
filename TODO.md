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

## Milestone 1: The IR & Optimizer Pipeline
- [x] Futhark-style map merging (Loop Fusion).
- [ ] Tail call & Leaf optimizations.
- [ ] Arithmetic expansion (IMUL, DIV, SSE/AVX for floats).

## Milestone 2: Memory & The "Variant" Type
- [x] Variant Types: Implement the 16-byte `Any` struct (Tag + Payload) for gradual typing.
- [x] The Shadow Stack: IR instructions to push/pop pointers for the GC.
- [x] The Allocator: Bump-pointer allocation in a pre-allocated `.data` or `mmap` arena.
- [/] Immix GC: Transition the current stub into a Mark-Region collector.
- [x] Smart Strings: UTF-8 strings with the O(1) offset-map header.
- [x] Defined-OR: Implement the `//` operator in Parser/Lowering.

## Milestone 3: Data Structures (The "Perl" Experience)
- [/] Arrays: Heap-allocated contiguous memory with bounds checking.
- [ ] Hashes: Built-in DJB2 or MurmurHash implementation in assembly.
- [/] Classes: first class based on perlclass (no bless) with method dispatch, inheritence, roles, etc.
- [ ] Tuples: Stack-allocated fixed-size structures.
- [ ] String Ops: Implement `eq`, `ne`, `lt`, `gt` using string-byte comparison.
- [ ] [Maybe] String Buffer: Implement `StringBuilder` for efficient string concatenation.

## Milestone 4: Advanced Runtime (Concurrency)
- [x] Fibers: Context switching by saving/restoring `rsp`/`sp` and registers.
- [ ] Isolates (OS Threads): Wrapping `CreateThread` (Win) and `clone`/`pthread` (Linux).
- [x] Windows TEB (Thread Environment Block) security mitigations.
- [ ] Channels: Lock-free ring buffers for Isolate-to-Isolate communication.
- [ ] [Maybe] Parallel Iterators: `pmap` and `pgrep`.

## Milestone 5: JIT-Powered FFI
- [ ] Symbol lookup: Implement pure-Perl manual Export Directory parsing for PE/ELF.
- [ ] Stabilize shared library output (.dll/.so): Verify cross-platform stability.
- [ ] Full Type System and ABI support: Marshalling structs, pointers, and large SIMD vectors.
- [ ] Compiler/IR: Implement `call_native` IR op and lowering logic.
- [ ] Reverse trampolines: Implement JIT stubs for callbacks.

## Milestone 6: Developer Experience & Correctness
- [ ] Compiler Test Suite and Fuzzing: Expand tests to stress-test the Register Allocator and GC boundary cases.
- [ ] IR-Diff Tool: Utility to verify output consistency between compiler versions (critical for self-hosting).
- [ ] LSP Stub: Basic IDE support for symbol definitions and type tooltips using POD6.

## Milestone 7: Ecosystem & Interop
- [ ] FFI (`Affix`): Declarative C-ABI bindings using opaque pointers.
  - *Note: Windows x64 requires arguments 5+ to be homed in the caller's pre-allocated shadow space `[rsp+32]`, while SysV uses `[rsp]`. We also must use `rcx`/`rdx` for args 1 & 2 on Win64 vs `rdi`/`rsi` on SysV. Shadow space must be maintained for SEH unwinding.*
- [ ] Regex Engine: PCRE-compatible engine compiled directly to machine code.
- [ ] Sandboxed `eval`: Embedded engine for capability-based security. File, process, and I/O operations should require permission grants.
- [ ] Self-hosting!
- [ ] The `bkn` (bacon) CLI: TOML manifests, Git dependencies, and reproducible builds.
