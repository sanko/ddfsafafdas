# Brocken Compiler Architecture

## What This Compiler Does

Brocken takes Brocken source code, chews through a few phases, and spits out a native executable. No GCC. No LLVM. No JIT library. Just Perl 5 and raw machine code bytes.

The supported output formats are Windows PE, Linux ELF, or macOS Mach-O, for x64 or ARM64.

This project serves two kinds of reader:

- **Perl programmers** curious about how compilers work
- **Compiler devs** who want to contribute new features, ports, or optimizations

## What Is a Compiler?

You already use one. `perl` compiles source to an optree, then walks it. Brocken does the same thing but keeps going - all the way to native code that the OS loads and runs directly.

The pipeline looks like this:

```
Source Code (Brocken)
    │
    ▼
┌─────────────┐  Lexer:  characters → tokens
│  Lexer      │
└─────────────┘
    │
    ▼
┌─────────────┐  Parser: tokens → AST
│  Parser     │
└─────────────┘
    │
    ▼
┌─────────────┐  Lowering: AST → IR
│  Lowering   │            + injects GC, fibers, printers, shadow stack
└─────────────┘
    │
    ▼
┌─────────────┐  Optimizer: IR → optimized IR (loop fusion, DCE)
│  Optimizer  │
└─────────────┘
    │
    ▼
┌─────────────┐  Codegen: IR → machine code (register allocation +
│  Codegen    │            instruction selection)
└─────────────┘
    │
    ▼
┌─────────────┐  Format: machine code → .exe / .elf / .macho
│  Format     │
└─────────────┘
    │
    ▼
Native Executable
```

Each phase lives in its own module under `lib/Brocken/`. The best way to get from "Perl user" to "compiler contributor" is to understand one phase at a time.

## Modules and What They Do

**`brocken.pl`** - Bootstrap script. Defines Brocken source as a heredoc, runs the full pipeline, then executes the compiled binary.

**`lib/Brocken/Lexer.pm`** - Tokenizer. Splits source into KEYWORD, IDENT, VAR, NUM, STRING, OP, punctuation, and EOF tokens.

**`lib/Brocken/Parser.pm`** - Pratt parser. Takes tokens, returns an AST.

**`lib/Brocken/AST.pm`** - All AST node types. Expressions (Const, Var, BinOp, etc.), statements (Block, VarDecl, If, While, Return, etc.), OOP (ClassDecl, Method, MethodCall, etc.), async (FiberBlock, Yield).

**`lib/Brocken/IR.pm`** - IR builder. Linear instruction sequence, virtual register allocation, labels, dump.

**`lib/Brocken/Compiler/Lowering.pm`** - The big one (~963 lines). Walks the AST and emits IR. Also injects the entire runtime inline - the GC, printers, fiber switcher, shadow stack, defer stack.

**`lib/Brocken/Compiler/Optimizer.pm`** - IR transforms. Currently loop fusion for chained `map` and dead code elimination.

**`lib/Brocken/Codegen.pm`** - Register allocator (linear scan) + instruction dispatcher.

**`lib/Brocken/Target/X64.pm`** - Maps every IR opcode to x64 machine code. Handles ABI, prologues/epilogues, shadow stack, control flow.

**`lib/Brocken/Target/X64/Emit.pm`** - Low-level x64 encoder. REX prefixes, ModR/M bytes, immediates, label fixups.

**`lib/Brocken/Target/ARM64/Emit.pm`** - ARM64 encoder skeleton. A64 instructions: register ops, ADRP addressing, branches.

**`lib/Brocken/Format/PE.pm`** - Windows PE64 writer. DOS header, NT headers, section table, import directory for kernel32.dll calls.

**`lib/Brocken/Format/ELF.pm`** - Linux ELF64 writer. ELF header + program headers for .text and .data.

**`lib/Brocken/Format/Layout.pm`** - Section layout calculator. File offsets and RVAs for .text, .data, .idata.

**`lib/Brocken/Compiler/DataSegment.pm`** - String constants with GC headers (leaf bit, byte length, char length).

**`lib/Brocken/Platform/Windows.pm`** - Windows intrinsics: VirtualAlloc, WriteFile, GetStdHandle, ExitProcess, VEH, fiber switch.

**`lib/Brocken/Platform/Linux.pm`** - Linux intrinsics: mmap (syscall 9), write (syscall 1), exit (syscall 60), fiber switch.

## Design Decisions That Matter

### Perl 5 with Corinna

The compiler is written in Perl 5.40 using the experimental `class` feature. That means every Perl programmer can read it, and the self-hosting phase (Phase 6) will compile the Brocken compiler using Brocken itself.

### Single-Pass Lowering

The AST is walked once. The IR is emitted linearly. No CFG, no SSA construction. Virtual registers are assigned exactly once, which is close enough to SSA for the linear scan allocator to work directly on the IR.

### Runtime Inline, Not Linked

Lowering.pm emits runtime functions as IR instructions. The GC allocator, the fiber switcher, the integer printer - all become machine code in the same .text section as user code. No separate runtime library to compile and link.

### Tagged Variants for Gradual Typing

`my $x` without a type gets **Any** - a 16-byte tagged variant (type tag + 64-bit payload). `my Int $x` gets a raw, unboxed machine integer. Same storage decision for every type.

### Shadow Stack for GC

The GC finds live pointers through a shadow stack - a parallel stack of pointer values updated alongside the real machine stack. Functions that allocate or hold references push/pop the shadow stack via `shadow_push`, `shadow_get`, `shadow_set` IR instructions.

## Running It

```bash
perl brocken.pl
```

That compiles the embedded test source and runs the binary. To use your own test code, edit `brocken.pl` around line 8 - the first `$source_code` assignment is the active one. Later ones are gated by `if 0` or `if 1`.

## Where to Go Next

If compilers are new to you, read them in order:

1. [Pipeline](pipeline.md) - The full pipeline from lexer to binary.
2. [Runtime](runtime.md) - GC, fibers, isolates, shadow stack.
3. [Code Generation](codegen.md) - IR set, register allocation, x64/ARM64 backends, binary formats.
4. [Extending](extending.md) - Adding keywords, platforms, targets, optimizations, and runtime.

## License

Artistic License 2.0 or MIT. Your choice.
