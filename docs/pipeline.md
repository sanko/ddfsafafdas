# The Brocken Compilation Pipeline

Seven phases. Each one transforms the program into a different representation. Here's the whole thing from `brocken.pl`'s point of view:

```perl
my $tokens   = Brocken::Lexer->new( source => $source_code )->lex();
my $ast      = Brocken::Parser->new( tokens => $tokens )->parse();
my $ds       = Brocken::Compiler::DataSegment->new();
my $lowering = Brocken::Compiler::Lowering->new(
    data_segment => $ds, driver => $p );
$lowering->lower_program($ast);
my $optimizer = Brocken::Compiler::Optimizer->new();
$optimizer->optimize( $lowering->builder );
my $codegen = Brocken::Codegen->new( arch => $p->arch );
$codegen->compile( [ $lowering->builder->instructions() ], $p );
$p->as->resolve();
$p->format->write_bin( $filename, $p->as->code, $ds->get_raw_data(),
    $p->arch, $p->os );
```

## Phase 1: Platform Detection

File: `lib/Brocken/Compiler.pm`

Before any source code touches the lexer, `Brocken::Compiler` figures out what OS and CPU we're on, then loads the right backend modules. This all happens in the ADJUST constructor.

```perl
my $detected_os =
      $^O eq 'MSWin32' ? 'win64'
    : ($^O eq 'darwin'  ? 'macos'
    : 'linux');
```

Architecture detection is similar — check `PROCESSOR_ARCHITECTURE` on Windows, `uname -m` elsewhere.

The Compiler object becomes the driver that every other phase uses to get ABI info, register lists, memory layout offsets, and format RVAs.

### What the driver provides

- `preserved_regs()` — callee-saved registers (Windows: rbx, rsi, rdi, r12-r15; SysV: rbx, r12-r15)
- `context_size()` / `context_offset(name)` — preserved register save area
- `frame_local_size()` — total frame: context + ret addr + shadow space (Windows) + locals, 16-byte aligned
- `iso_offset(name)` / `fcb_offset(name)` — field offsets in Isolate/Fiber control blocks
- `cc(name)` — condition code mapping for branches

## Phase 2: Lexer

File: `lib/Brocken/Lexer.pm` (68 lines)

Turns source text into an array of tokens. Each token is a hash: `{ type, value, line, col }`.

### Tokens

| Type | Examples |
|------|----------|
| `NUM` | `42` |
| `STRING` | `"hello"` |
| `KEYWORD` | `my`, `sub`, `class`, `if`, `while`, `return` |
| `IDENT` | `foo`, `x`, `multiply` |
| `VAR` | `$x`, `@arr`, `%hash` |
| `OP` | `+`, `==`, `<<`, `\|\|`, `->` |
| `{};(),` | single-char punctuation |
| `EOF` | end sentinel |

### How it works

The lexer tries patterns in priority order. Comments get discarded. Position tracking is maintained for error messages.

```perl
while ( $pos < length($source) ) {
    my $remaining = substr( $source, $pos );
    if ( $remaining =~ /^(\s+)/ )     { ... skip whitespace ... }
    if ( $remaining =~ /^(#[^\n]*)/ ) { ... skip comments ... }
    if ( $remaining =~ /^(\d+)/ )     { push @tokens, token('NUM', $1); }
    if ( $remaining =~ /^"((?:[^"\\]|\\.)*)"/s ) { ... parse string ... }
    if ( $remaining =~ /^([\$@%]?[a-zA-Z_]\w*)/ ) { ... keyword/ident/var ... }
    if ( $remaining =~ /^(==|!=|<=|>=|=>|->|&&|\|\|)/ ) { ... multi-char op ... }
    if ( $remaining =~ /^([+\-*\/=<>\[\].:!?])/ )       { ... single-char op ... }
    if ( $remaining =~ /^([{};(),])/ )                   { ... punctuation ... }
}
```

Keywords are in a hash for O(1) lookup:

```perl
my %KEYWORDS = map { $_ => 1 } qw[
    my our state
    class method field
    return exit
    sub
    fiber yield
    defer
    if else unless
    while for map
    say print
    Int String Any Bool
    true false
];
```

## Phase 3: Parser

File: `lib/Brocken/Parser.pm` (435 lines)

Pratt parser — top-down operator precedence. Three registries:

- **Statement handlers** (`%STMT_HANDLERS`): keyword → parsing method. `if` → `_parse_if`.
- **Prefix handlers** (`%PREFIX_HANDLERS`): tokens that start expressions — literals, variables, identifiers, `!`, `(`, `sub`, `fiber`, `yield`, `map`.
- **Infix handlers** (`%INFIX_HANDLERS`): binary operators — arithmetic, comparison, logical, assignment, `->`, `?`.

### Precedence

```perl
'='  => 10,   '?'  => 11,   '||' => 12,   '&&' => 13,
'==' => 15,   '+'  => 20,   '-'  => 20,
'*'  => 30,   '/'  => 30,   '['  => 50,
'->' => 60,   '('  => 70,
```

Higher number = binds tighter. Assignment is right-associative. The left side of `=` must be a variable.

### Core loop

```perl
method parse_expression( $precedence = 0 ) {
    my $tok  = $self->current;
    my $prefix_method = $PREFIX_HANDLERS{ $tok->{value} }
                     // $PREFIX_HANDLERS{ $tok->{type} };
    my $left = $self->$prefix_method($tok);
    while ( $precedence < ( $PRECEDENCE{ $self->current->{value} } // 0 ) ) {
        my $op           = $self->current->{value};
        my $infix_method = $INFIX_HANDLERS{$op};
        last unless $infix_method;
        $self->advance();
        $left = $self->$infix_method( $left, $op );
    }
    return $left;
}
```

If a statement doesn't match a keyword handler, it falls through to expression parsing. So `$x = 10;` parses as an expression statement.

### AST node types

```
Brocken::AST::Node
├── Expr::Const       — literal values
├── Expr::Var         — variable references
├── Expr::BinOp       — binary operators
├── Expr::UnaryOp     — unary operators (!)
├── Expr::Ternary     — cond ? then : else
├── Expr::Call        — function calls
├── Expr::AnonCall    — $f->()
├── Expr::ArrayLiteral — [1, 2, 3]
├── Expr::IndexExpr   — @arr[0]
├── Stmt::Block       — { ... }
├── Stmt::VarDecl     — my declarations
├── Stmt::StateDecl   — state declarations
├── Stmt::Assignment  — variable assignment
├── Stmt::If          — if/elsif/else
├── Stmt::While       — while loops
├── Stmt::Return      — return
├── Stmt::Exit        — exit
├── Stmt::Map         — map { ... } source
├── Stmt::Defer       — defer { ... }
├── OOP::ClassDecl    — class declarations
├── OOP::FieldDecl    — field declarations
├── OOP::Method       — method/sub declarations
├── OOP::MethodCall   — $obj->method(...)
├── OOP::AnonSub      — sub (...) { ... }
├── Async::FiberBlock — fiber { ... }
└── Async::Yield      — yield expr
```

## Phase 4: Data Segment

File: `lib/Brocken/Compiler/DataSegment.pm` (36 lines)

Holds string constants before lowering starts. Each string gets a GC-compatible header: 1 byte flags (bit 0 = leaf bit), 4 bytes byte length, 4 bytes char length. `add_string()` returns a pointer to the data right after the header.

During lowering, string constants turn into `load_data_addr` IR instructions referencing offsets into this segment.

## Phase 5: Lowering (AST → IR)

File: `lib/Brocken/Compiler/Lowering.pm` (963 lines)

This is where the compiler actually does its work. Walks every AST node, emits linear IR. Also dumps the entire runtime into the instruction stream — GC, printers, fiber switcher, everything.

### IR format

```perl
{ op => 'add', type => 'Int', dest => '%5', args => ['%3', '%4'] }
```

Plus special forms: `label` (code location), `jmp` (unconditional), `cond_br` (conditional branch).

Every lowering method returns `($virtual_register, $type)`.

### What lowering does for common constructs

**`my Int $x = 42`**:
1. Allocate a local stack slot
2. Lower the initializer (get a vreg)
3. Emit `local_store` to write the vreg into the slot
4. Map `$x` → slot number in the current scope

**`if (cond) { ... } else { ... }`**:
1. Lower condition → boolean vreg
2. Emit `cond_br` with then/else labels
3. Lower then-block after L_then, jump to L_end
4. Lower else-block after L_else
5. Emit L_end

**`sub foo(Int $x) { ... }`**:
1. New scope, increment `$routine_depth`
2. Emit `enter_func` (push preserved regs, allocate frame)
3. Map parameters to slots, emit `get_arg` for each
4. Lower body
5. Emit `leave_func` (rax = return value, restore regs, ret)

### Runtime functions injected

- `M_gc_alloc` — Immix bump allocator (128-byte lines, 32KB blocks)
- `M_gc_collect` — root-walk from shadow stacks, mark with cycle detection
- `M_gc_mark_obj` — mark objects (arrays, class instances)
- `M_print_int` — divide-by-10 loop, write digits to stdout
- `M_print_any` — tagged variant printer
- `M_fiber_new` — allocate FCB, set up stack + shadow stack
- `M_fiber_switch` — context switch: save/restore RSP and preserved regs
- `M_veh_handler` — Windows VEH for stack overflow recovery

## Phase 6: Optimizer

File: `lib/Brocken/Compiler/Optimizer.pm` (57 lines)

Two passes:

**Loop fusion**: Chains of `map { ... } map { ... }` get fused into a single loop. The optimizer finds adjacent `map_op` instructions, merges the body of one into the other, and removes the intermediate.

**Dead code elimination**: If an instruction's destination vreg is never read, the instruction is deleted. Liveness analysis determines this.

## Phase 7: Code Generation

File: `lib/Brocken/Codegen.pm` (67 lines)

Three jobs:

1. **Liveness analysis** — for each vreg, find where it's first defined and last used.
2. **Linear scan register allocation** — sort vregs by start position, maintain active list, spill when out of registers. The spill goes to a local stack slot via `local_load`/`local_store`. Iterates until convergence (usually 2-3 rounds).
3. **Instruction dispatch** — each IR instruction goes to the target backend's `emit_op` (or `compile_intrinsic` for OS-specific ops).

Available registers:
- Windows x64: `rbx, rsi, rdi, r12, r13, r15` (6)
- SysV x64: `rbx, r12, r13, r15` (4)

Volatile registers (rax, rcx, rdx, r8-r11) are excluded — function calls can clobber them at any time.

After dispatch, `resolve()` patches label references in the code stream.

## Phase 8: Binary Format

Files: `lib/Brocken/Format/{PE,ELF,Layout}.pm`

Packages machine code + data into an executable.

Layout manages three sections: `.text` (code), `.data` (strings + GC heap), `.idata` (PE import table). Computes file offsets and RVAs.

**PE** (Windows): DOS header → NT headers → section table → import directory for kernel32.dll (ExitProcess, GetStdHandle, WriteFile, VirtualAlloc, SetConsoleOutputCP, AddVectoredExceptionHandler).

**ELF** (Linux): ELF header → two PT_LOAD segments (.text RX, .data RW) → code/data at computed offsets.

## Phase 9: Execution

```perl
my $run = $^O eq 'MSWin32' ? $exe : "./$exe";
system( 'gdb --batch -ex "run" ... --args ' . $run );
```

Linux runs through GDB (backtrace on crash). Windows runs directly. Exit code is captured.
