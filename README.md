# ...what is Brocken?

It's my take on an alternate reality where Perl didn't peak in the grunge era.

Brocken is a high performance, self-hosting, compiled language designed for system programming, data processing, and concurrency. The goal is to retain the expressive text processing power of Perl but strip away the historical baggage in favor of modern defaults like `use strict` by default, optional strong types, UTF-8 everywhere, and a modern object system baked in from day one.

Brocken compiles directly to native machine code for x64 and ARM64 on Windows, Linux, and macOS. It features a zero dependency runtime, cooperative Fibers, preemptive Isolates, and a custom Immix style garbage collector.

# ...why is Brocken?

Perl revolutionized how we process text and manage logic, but decades of backward compatibility have created a steep barrier to entry for modern systems tasks.

I've written a lot of code in and for Perl.

Why am I using Perl?

# Okay, but what is Brocken?

Brocken is an AOT compiled systems language that retains Perl's expressive power and text-processing supremacy while fixing historical pain points. Every gripe in this document is my opinion, by the way. That should be obvious but...

Brocken compiles to native x64/ARM64 binaries for Linux, Windows, and macOS with zero dependencies. I decided early that Brocken will cross compile for any supported platform to any other supported platform because I want to be able to develop and build on my AMD powered desktop and then move binaries onto my ARM based Chromebook. I also wanted it to be self hosting. In fact, Brocken's binaries should be able to be built by Brocken itself or with the Perl 5 interpreter. Imagine a standard Perl language compiler in every place Perl already exists? Living the dream!

# Quick Start

Uh. It's a brand new project so I guess you could just try this:

```bash
# Compile and run the prototype
perl brocken.pl
```

# Brocken at a glance

I'm aiming for the middle ground between Perl and Raku, I guess.

| Feature           | Perl 5          | Brocken         | Raku             |
|-------------------|-----------------|-----------------|------------------|
| **Compilation**   | Interpreter     | AOT (Native)    | VM (MoarVM)      |
| **Debugging**     | [`perl -d`](https://perldoc.perl.org/perldebug)  | GDB (DWARF)     | [trace and dump](https://docs.raku.org/programs/01-debugging) |
| **Typing**        | Dynamic (Weak)  | Gradual         | Gradual          |
| **Concurrency**   | Threads (Heavy) | Fibers/Isolates | Supply/Channel   |
| **Memory**        | Ref-counting    | Mark-Region GC  | Generational GC  |
| **FFI**           | XS (Complex)    | Native `affix`  | NativeCall       |

## Example Code

You've probably seen Perl. You may know Perl. Brocken combines modern syntax with system-level control.

```perl
sub multiply(Int $val, Int $factor) {
    return $val * $factor;
}

my Int $x = 10;
my Int $result = multiply($x, 2);  # Calls our method!

say "Result: $result";  # Output: Result: 20
```

```perl
# Native, memory-safe classes with typed fields
class User {
    field Int $id;
    field String $status;

    method set_id(Int $val) {
        $id = $val;
        $status = "Active";
    }
}

my User $u = User->new();
$u->set_id(42);
```

```perl
# Cooperative Fibers for things like non-blocking I/O
my Any $gen = fiber {
    say "Fiber booting...";
    yield 100;
    say "Fiber shutting down...";
    return 200;
};

my Int $res1 = transfer($gen, 0); # 100
my Int $res2 = transfer($gen, 0); # 200
```

# Debugging

Brocken emits full DWARF debug information and SEH tables, allowing you to use standard debuggers (GDB/LLDB) to step through your source code.

## Debug Levels

Pass `debug => N` to `Brocken::Compiler` or `--debug=N` to `brocken.pl`:

| Level | Effect |
|-------|--------|
| **0** | No debug information. Lean binary. (Default) |
| **1** | Emit all DWARF sections + SEH (win64) + `.eh_frame` (linux). Source location tracking. |
| **2** | Same as 1, plus hex dumps of debug sections. |
| **4** | Include class/struct type information in `.debug_info`. |

## GDB

```bash
# Linux - source-level breakpoints via .debug_line + .eh_frame
gdb --batch \
  -ex "break source.brocken:9" \
  -ex "run" \
  -ex "bt" \
  --args ./brocken_out

# Windows - break by address, unwind via SEH .pdata/.xdata
gdb --batch \
  -ex "break *0x140001000" \
  -ex "run" \
  -ex "bt" \
  --args brocken_out.exe
```

While I'm still designing this, you could build a debugging version of the inline demo:

```bash
perl brocken.pl --debug=1
# Step through using GDB
gdb --batch -ex "break source.brocken:9" -ex "run" -ex "bt" ./brocken_out
```

For full details on every debug section, see [`docs/debugging.md`](docs/debugging.md).

## Troubleshooting

### GDB shows "No symbol" or "No frame selected"

Brocken emits DWARF debug info, but GDB needs correct addresses. The compiler prints source location mappings:

```
--- DEBUG SOURCE LOCATIONS ---
  offset=0x170C  line=1    col=8
  offset=0x171A  line=2    col=8
  ...
```

Use `objdump --dwarf=decodedline brocken_out.exe` to get the actual runtime addresses of source lines. Set breakpoints by address:

```bash
# Linux
gdb --batch -ex "break *0x1400018B0" -ex "run" -ex "bt" -ex "info locals" --args ./brocken_out

# Windows (PE)
gdb --batch -ex "break *0x140002889" -ex "run" -ex "bt" -ex "info locals" --args brocken_out.exe
```

### Source-level breakpoints don't work

On Windows (PE), GDB may have trouble auto-discovering debug sections due to COFF truncation. Break by address using the `objdump` output above.

On Linux, source-level breakpoints (`break source.brocken:N`) should work if `.debug_line` is present.

### "No symbol" for variable names

This means the DWARF location expressions are incorrect or the variables were optimized away. Check with `bt full` which shows all locals with values:

```bash
gdb --batch -ex "break *0x140002889" -ex "run" -ex "bt full" --args brocken_out.exe
```

### Variables show wrong values

If `info locals` shows variables like `counter = 3` instead of `counter = 1`, the variables may have been modified before the breakpoint or the location expression is offset by one slot. Use `x/8xg $rbp` to inspect raw frame memory and verify offsets.

### Debug info size

Debug sections add significant size to binaries. For lean binaries:
- `--debug=0` - no debug info
- `--debug=1` - DWARF + unwind info only
- `--debug=2` - DWARF + hex dumps (default)

For full details, see [`docs/debugging.md`](docs/debugging.md).

# Notes

This is just a collection of links I'm using to help define what this language is:

- https://www.perl.com/article/my-perl-wishlist-invariant-sigils-part-1/
- https://dev.to/thibaultduponchelle/my-unrealistic-wish-list-for-perl-7-x-4pg9#More

# License

Brocken is licensed under either the Artistic License 2.0 or MIT. You pick.
