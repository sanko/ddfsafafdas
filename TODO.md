# Language Milestones & TODO

## **Milestone 0: The Binary Foundation**
- [x] Pure Perl X64 Emitter.
- [x] PE64 (Windows) Formatter.
- [x] ELF64 (Linux) Formatter.
- [x] Mach-O (macOS) Formatter.
- [x] Position Independent Code (ASLR support).
- [x] Basic System Calls / WinAPI Imports.
- [x] Automated Layout Manager (Section & Offset tracking).

## **Milestone 1: The IR & Optimizer Pipeline**
- [x] Lexer, Parser, and AST Generation.
- [x] SSA IR Builder and Liveness Analysis.
- [x] Register Allocation (Linear Scan / Graph Coloring).
- [x] Futhark-style map merging (Loop Fusion).
- [ ] Tail call & Leaf optimizations.
- [ ] Arithmetic expansion (IMUL, DIV, SSE/AVX for floats).

## **Milestone 2: Memory & The "Variant" Type**
- [ ] Variant Types: Implement the 16-byte `Any` struct (Tag + Payload) for gradual typing.
- [ ] The Shadow Stack: IR instructions to push/pop pointers for the GC.
- [ ] The Allocator: Bump-pointer allocation in a pre-allocated `.data` or `mmap` arena.
- [ ] Cheney GC: The semi-space copying algorithm (triggered when the bump allocator fills).
- [ ] Smart Strings: UTF-8 strings with the O(1) offset-map header.

## **Milestone 3: Data Structures (The "Perl" Experience)**
- [ ] Arrays: Heap-allocated contiguous memory with bounds checking.
- [ ] Hashes: Built-in DJB2 or MurmurHash implementation in assembly.
- [ ] Classes: first class based on perlclass (no bless) with method dispatch, inheritence, roles, etc.
- [ ] Tuples: Stack-allocated fixed-size structures.
- [ ] Context: The `match want` dynamic return dispatcher.

## **Milestone 4: Advanced Runtime (Concurrency)**
- [ ] Fibers: Context switching by saving/restoring `rsp`/`sp` and registers.
- [ ] Isolates (OS Threads): Wrapping `CreateThread` (Win) and `clone`/`pthread` (Linux).
- [ ] Channels: Lock-free ring buffers for Isolate-to-Isolate communication.
- [ ] Parallel Iterators: `pmap` and `pgrep`.

## **Milestone 5: Ecosystem & Interop**
- [ ] Regex Engine: PCRE-compatible engine compiled directly to machine code.
- [ ] FFI (`Affix`): Declarative C-ABI bindings using opaque pointers.
- [ ] Sandboxed `eval`: Embedded Wasm engine for capability-based security.
- [ ] The `bkn` CLI: TOML manifests, Git dependencies, and reproducible builds.
