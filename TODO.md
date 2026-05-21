# Current task list:

We wrote a compiler in pure perl. Implement the following features:

 - [ ] __LINE__, __FILE__, __PACKAGE__, __CLASS__, __ENND__, __DATA__,etc
 - [x] Add the ability to handle `#line` directives like perl, C, etc. Implement a nur
 - [ ] Enhance our RC Immix implementation with a nursery for short lived allocations.
 - [ ] Implement `our` for package level globals.
 - [ ] `dump` keyword that pretty prints vars (scalars, lists, hashes, and even class objects); maybe in JSON?
 - [x] `...` yada-yada stub from Perl
 - [ ] Implement these loop keywords (they should behave exactly as they do in perl 5.40):
     - [x] `next`
     - [x] `last`
     - [x] `redo`
     - [x] `for` loop.  All of these examples should work:
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

See our TODO.md file for moe.

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
- [x] Immix GC: Transition the current stub into a Mark-Region collector.
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
- [ ] Generational GC (The Nursery): Implement a "Sticky" Immix generation. Allocate all new objects in a small (e.g., 2MB) window and only scan this nursery for quick collections. Tenured objects get promoted to the main heap.

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
