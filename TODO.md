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
- [ ] Immix GC: Transition the current stub into a Mark-Region collector.
- [ ] Smart Strings: UTF-8 strings with the O(1) offset-map header.
- [ ] Defined-OR: Implement the `//` operator in Parser/Lowering.

## **Milestone 3: Data Structures (The "Perl" Experience)**
- [ ] Arrays: Heap-allocated contiguous memory with bounds checking.
- [ ] Hashes: Built-in DJB2 or MurmurHash implementation in assembly.
- [ ] Classes: first class based on perlclass (no bless) with method dispatch, inheritence, roles, etc.
- [ ] Tuples: Stack-allocated fixed-size structures.
- [ ] String Ops: Implement `eq`, `ne`, `lt`, `gt` using string-byte comparison.

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




# PART 1: The Brocken Project Master Plan

## 1. Executive Summary
**Project Brocken** is an Ahead-of-Time (AOT) compiler written in pure Perl. It compiles a modern, strict, gradually typed dialect of Perl directly into raw, executable machine code (Windows PE, Linux ELF, macOS Mach-O) without relying on intermediate C compilers, GCC, or LLVM. It features true OS-level stackful fibers, shared-nothing concurrency (Isolates), a custom Tracing Garbage Collector, and native zero-overhead OOP.

The ultimate goal is **Stage 3 Self-Hosting**: compiling the Brocken compiler using itself, resulting in a bit-for-bit identical native executable.

---

## 2. Language Specification (The Brocken Dialect)
Brocken is not fully backward-compatible with Perl 5. It strips away legacy cruft in favor of high-performance systems programming primitives.

### Variables & Typing (Gradual Typing)
Variables are statically scoped. Types are optional but highly encouraged. Untyped variables default to `Any` (dynamically boxed values).
*   **Primitives:** `Int`, `String`, `Array`, `Any`
*   **Syntax:** `my Int $x = 10;`, `my $y = "Dynamic";`
*   **State:** `state Int $counter = 0;` (Persists across function calls).

### Native OOP (`class`, `field`, `method`)
Replaces traditional `bless` and `%hash` objects with native C-style `structs` and VTable dynamic dispatch.
*   **Fields:** Strongly typed memory offsets.
*   **Methods:** Native functions with a hidden `$self` pointer.
```perl
class User {
    field Int $id;
    method set_id(Int $val) { $id = $val; }
}
```

### Concurrency (Fibers & Isolates)
*   **Fibers:** True, stackful coroutines. Variables and execution states are preserved perfectly. Uses `yield` to pause and `transfer` to pass control and data.
*   **Isolates:** OS-level threads with shared-nothing memory. Lock-free by default. Each isolate has its own Garbage Collector arena.

### Advanced Features (Planned)
*   **Compile-Time Macros:** `BEGIN` blocks execute *during* the lowering phase to rewrite the AST (e.g., implementing beginner-friendly invariant sigils).
*   **AOT FFI:** Direct bindings to the C ABI using `Affix` syntax. `affix 'libm', 'cos', [Double], Double;` emits raw native C-calls, skipping JIT/libffi.

---

## 3. Project Milestones & Estimated Timeline (12-16 Weeks)

### ✅ Phase 1: The Foundation (Weeks 1-2) - *COMPLETED*
*   [x] Custom Lexer with UTF-8 support.
*   [x] Pratt/Recursive-Descent Parser.
*   [x] AST definition.
*   [x] Linear Intermediate Representation (IR) Builder.

### ✅ Phase 2: The Emitter & OS Integration (Weeks 3-5) - *COMPLETED*
*   [x] Linear Scan Register Allocator.
*   [x] x64 Machine Code Emitter (ModR/M bytes, REX prefixes).
*   [x] Executable Linkable Format Emitters (Windows PE, Linux ELF, macOS Mach-O).
*   [x] Bootstrapping basic arithmetic and local variables.

### ✅ Phase 3: Advanced Control Flow & Native OOP (Weeks 6-7) - *COMPLETED*
*   [x] Control Flow (`if`, `while`, boolean logic).
*   [x] Classes & VTable dispatch.
*   [x] Lexical scoping and shadowing.
*   [x] Shadow stack setup for the Garbage Collector.

### 🚧 Phase 4: Concurrency & Advanced Memory (Weeks 8-10) - *IN PROGRESS*
*   [x] Fiber AST integration.
*   [x] Fiber context switching (Assembly `RSP` swapping).
*   [x] Windows TEB (Thread Environment Block) security mitigations.
*   [ ] **Pending:** Transition the stub Mark-Sweep GC into a full **Immix** (Mark-Region) GC.
*   [ ] **Pending:** Implement `defer` blocks for deterministic cleanup outside the GC.

### 🎯 Phase 5: FFI & The Standard Library (Weeks 11-12)
*   [ ] Implement static `affix` calls mapping to the `.idata` (Import Directory) in the PE/ELF headers.
*   [ ] Build out a minimal core library (File I/O, OS interactions) using FFI.
*   [ ] Implement OS-level Thread spawning for the Isolate model.

### 🐉 Phase 6: The Final Boss - Self-Hosting (Weeks 13-16)
*[ ] Translate `Brocken::Compiler` into the strict Brocken Perl dialect.
*   [ ] Run Compiler A (running on `perl`) to compile Compiler B (Brocken code).
*   [ ] Run Compiler B.exe to compile Compiler B (Brocken code) -> Produces Compiler C.exe.
*   [ ] Verify Compiler B.exe and Compiler C.exe are bit-for-bit identical.

---

## 4. Topics to Consider / Waypoints

*   **String Encoding:** Currently handled as raw bytes. Ensure Immix GC headers include string length fields so strings can contain null bytes (`\0`) safely.
*   **The ARM64 Backend:** You have the `Emit::ARM64` skeleton. Before self-hosting, you need to write the `compile` logic for ARM64 in `Codegen.pm` (mapping IR to ARM64 opcodes).
*   **Error Handling (Panics):** Implement a `die` / `panic` keyword that triggers a stack trace. Because you are generating native code, you will need to implement DWARF / PE exception unwinding or a simple setjmp/longjmp shadow stack for `eval { }` blocks.
*   **Memory Leaks during compilation:** When running in self-hosted mode, the compiler will allocate millions of AST nodes. Ensure your Immix GC is rock-solid before attempting the Stage 2 bootstrap, or the compiler will run out of memory compiling itself.

---

## 5. Pro-Tips for Compiler Engineering

1.  **Never Silence the Linker:** Always hard-fail (`die`) if a jump target or function label cannot be resolved. A silent jump to `0x0` will ruin your week.
2.  **Volatile Registers:** Treat ABI Volatile registers (RAX, RCX, RDX, R8, R9, R10, R11) like radioactive waste. Never let your register allocator assign long-living variables to them.
3.  **16-Byte Stack Alignment:** The x64 C-ABI strictly requires the stack pointer (`RSP`) to be aligned to 16 bytes immediately *before* a `call` instruction. If printf or FFI randomly segfaults, it is *always* stack alignment.
4.  **The "Dump IR" is your best friend:** Keep your `dump_ir` output clean. Before looking at assembly or GDB, read the linear IR. 90% of bugs are visible there.

