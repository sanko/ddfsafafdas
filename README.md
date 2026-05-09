# ...what?

Brocken is my take on an alternate reality where Perl didn't peak in the grunge era. Before you waste your time reading any further, understand that is very much alpha software.

Imagine a language as flexible as Perl, the highly expressive, text processing powerhouse, but without all the backwards compatibility blah blah. Picture a self-hosted compiled language that can build native binaries for Windows, Linux, or macOS. A compiler that can cross compile executibles for any operating system and any processor architecture.

Now, with that in your head, rub down all the things that new folks get hung up on with Perl: sigils, the lack of built-in concurrency, unweildy tooling, difficult packaging. Perl with modern defaults like strict, UTF-8, a type system, and a single modern object system baked in.

# Why?

I've written and maintained dozens of modules written in Perl over the years. GUI toolkit wrappers, an entire FFI system, an incredibly complete BitTorrent client library, social network software, and yet another template system. There's even a little hardware hacking in there with a driver for a color display on a Raspberry Pi and a replacement service for an old Motorola AOL instant messenger device. Most of my entire life, I've written most of my personal projects in Perl and after all of that, I honestly cannot recall anything I've ever written being used by anyone who wasn't me. I have basically written all that code for myself and while I obviously like Perl, nothing is specifically keeping me in the Perl ecosystem. Why am I living with the limits and rough edges of the language to maintain compatability with my own local use?

Why am I using Perl?

# Okay, but what is Brocken?

Brocken is an AOT compiled systems language that retains Perl's expressive power and text-processing supremacy while fixing historical pain points. Every gripe in this document is my opinion, by the way. That should be obvious but...

Brocken compiles to native x64/ARM64 binaries for Linux, Windows, and macOS with zero dependencies. I decided early that Brocken will cross compile for any supported platform to any other supported platform because I want to be able to develop and build on my AMD powered desktop and then move binaries onto my ARM based Chromebook. I also wanted it to be self hosting. In fact, Brocken's binaries should be able to be built by Brocken itself or with the Perl 5 interpreter. Imagine a standard Perl language compiler in every place Perl already exists? Living the dream!

## Quick Start

Uh. It's a week old so I guess you could just try this:

```bash
# Build the compiler prototype
perl brocken.pl
```

## Example Code

You've seen Perl. It's (mostly) the same:

```perl
sub multiply(Int $val, Int $factor) {
    return $val * $factor;
}

my Int $x = 10;
my Int $result = multiply($x, 2);  # Calls our method!

say "Result: $result";  # Output: Result: 20
```


```perl
# Native, memory-safe classes
class User {
    field Int $id;
    field String $status;

    method set_id(Int $val) {
        $id = $val;
        $status = "Active";
    }
}

# Blazing fast execution
my User $u = User->new();
$u->set_id(42);

# True OS-Level Fibers
my Any $gen = fiber {
    say "Fiber booting...";
    yield 100;
    say "Fiber shutting down...";
    return 200;
};

my Int $res1 = transfer($gen, 0); # 100
my Int $res2 = transfer($gen, 0); # 200
```


## I. Core Language Semantics
*   **Safety by Default:** Variables must be declared. Strict types are gradual but enforced when used. Source code and all strings are strictly UTF-8.
*   **Invariant Sigils:** Sigils indicate the structural container type, not the access context.
    *   `$` = Scalar / Reference (e.g., `my $string`, `my $obj`, `my Array[Int] $ref`)
    *   `@` = Array (e.g., `my Int @list`)
    *   `%` = Hash (e.g., `my String %map`)
*   **Automatic Dereferencing:** No more `->` or `@{}`. If `$user` is a hash reference, `$user{name}` works automatically.
*   **OOP (Corinna-inspired):** First-class `class`, `method`, and `field` keywords. No `bless`.
*   **Contextual Dispatch (`match want`):** Methods can inspect the caller's requested type (String, Int, Fiber, Void) and alter their return values natively using AOT jump tables.
*   **Lexical Magic:** Special variables like `$_` are strictly lexical or Fiber-local to prevent global state corruption.
*   **Typed Exceptions:** Handled via `try { ... } catch ($e) { match $e { ... } }`.
*   **Gradual Typing ("Loose by default, tight for speed"):** Untyped variables (`my $var`) fall back to a dynamic Tagged Variant for rapid, flexible prototyping. Explicitly typed variables (`my Int $x`, `my Array[String] @list`) compile down to unboxed, raw machine types, unlocking zero-overhead C-level performance.
*   **Smart-String Internals:** Strings are natively UTF-8 but utilize advanced optimizations (Small String Optimization, pure-ASCII fast-paths, and lazy offset/breadcrumb tracking). This guarantees O(1) or near-O(1) access to proper Grapheme clusters (emojis, combined accents) without memory corruption or performance cliffs.
*   **Pod6 Documentation:** Raku-style Pod6 is built natively into the parser. Documentation blocks and declarative comments (`#|`) are attached directly to the AST, allowing the compiler to provide rich data directly to IDEs (LSP) and the unified `bkn doc` tool.

## II. Data Processing & Optimizations
*   **Core Toolkit:** All standard Perl functional tools (`map`, `grep`, `pack`, `unpack`, `join`, `split`) are baked into the core AOT compiler.
*   **PCRE Integration:** First-class regex syntax compiled natively.
*   **Loop Fusion (Futhark-style):** The compiler optimizes chained functional calls (`map -> grep -> map`) into a single C-style `for` loop, eliminating intermediate memory allocations.
*   **Parallel Iterators:** Native support for chunking arrays across Isolates.
    *   *Syntax Idea:* `my @results = pmap { $_ * heavy_math() } @dataset;`

## III. Concurrency & Memory Model
*   **Garbage Collection:** Precise, Semi-Space Copying GC (Cheney's Algorithm) utilizing a Shadow Stack. Lock-free and blazing fast.
*   **Fibers (Wren-inspired):** Stackful, lightweight coroutines. They use cooperative scheduling (`yield` / `$fiber->()`) and live inside a specific Isolate's memory arena.
*   **Isolates:** OS-level threads. They share **no** memory and have independent GCs.
*   **Channels:** Isolates communicate purely by passing data through lock-free ring buffers (Channels). Complex data is automatically deep-copied across the Isolate boundary; primitive/immutable data is passed by pointer.

## IV. Interoperability & Security
*   **The FFI (`Affix`):** Zero C-compilation required. Use `affix 'sqlite3', 'sqlite3_open', [String, Pointer], Int;` to generate AOT C-ABI calls using opaque Pointers.
*   **Sandboxed `eval`:** `eval $string` compiles the string into an ephemeral Wasm(?) module, executed in an embedded engine. Capability-based security (`permit('system')`) guarantees 100% unbreakable hardware-level isolation.

## V. Ecosystem & Tooling
*   **The `bkn` CLI:** A unified tool for building, testing, and dependency management.
*   **Manifests over Scripts:** `brocken.toml` replaces `Makefile.PL`. Declarative dependencies map Git repositories directly to Perl namespaces (e.g., `@acme/json` maps to `use JSON;`).
*   **Reproducible Builds:** Global cache with project-local `brocken.lock` files.
*   **Sandboxed Build Scripts:** If a C library must be compiled, `build.bkn` executes within the restricted Wasm capability sandbox to prevent supply-chain attacks.

## Debugging

Brocken emits two independent debug information systems, selected by target OS:

| System                | Target       | Purpose                        |
|-----------------------|--------------|--------------------------------|
| DWARF (`.debug_*`)    | PE + ELF     | Source-level debugging with GDB |
| SEH (`.pdata`/`.xdata`) | PE (win64) | Stack unwinding with GDB/WinDbg |
| `.eh_frame`           | ELF (linux)  | Position-independent unwinding  |

### Debug Levels

Pass `--debug=N` to `brocken.pl`:

| Level | Effect |
|-------|--------|
| **0** | No debug information. Lean binary. |
| **1** | Emit all DWARF sections + SEH (win64) + `.eh_frame` (linux). Launch GDB. |
| **2** | Same as 1, plus hex dumps of debug sections. (Default) |
| **4** | Include class/struct types in `.debug_info`. |

```bash
perl brocken.pl               # debug=2 (default)
perl brocken.pl --debug=1     # less verbose
perl brocken.pl --debug=0     # no debug info at all
```

### GDB

```bash
# Linux — source-level breakpoints via .debug_line + .eh_frame
gdb --batch \
  -ex "break source.brocken:9" \
  -ex "run" \
  -ex "bt" \
  --args ./brocken_out

# Windows — break by address, unwind via SEH .pdata/.xdata
gdb --batch \
  -ex "break *0x140001000" \
  -ex "run" \
  -ex "bt" \
  --args brocken_out.exe
```

For full details on every debug section, see [`docs/debugging.md`](docs/debugging.md).

## Notes

This is just a collection of links I'm using to help define what this language is:

- https://www.perl.com/article/my-perl-wishlist-invariant-sigils-part-1/
- https://dev.to/thibaultduponchelle/my-unrealistic-wish-list-for-perl-7-x-4pg9#More

# License

Brocken is licensed under either the Artistic License 2.0 or MIT. You pick.
