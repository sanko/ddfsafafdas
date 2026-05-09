# Fuzzing System

Brocken's fuzzing system generates random inputs and feeds them through
the compiler pipeline to discover crashes, panics, or assertion failures.

## Tools

### `fuzz_ir.pl` — Multi-target IR and source fuzzer

The primary harness. Generates random IR instruction sequences, source
code fragments, and edge-case inputs, then runs them through the compiler
pipeline.

```bash
perl fuzz/fuzz_ir.pl                          # 1000 iterations, all targets
perl fuzz/fuzz_ir.pl --iterations=10000        # More iterations
perl fuzz/fuzz_ir.pl --iterations=500 --target=lexer
perl fuzz/fuzz_ir.pl --target=source           # Full pipeline fuzzing
perl fuzz/fuzz_ir.pl --resume=crashes.log       # Resume from crash log
```

**Targets:** codegen, emitter, format, lexer, parser, source, lowering, dwarf, seh

### `fuzz_ast.pl` — Property-based AST fuzzing

Generates random Brocken ASTs directly (bypassing the parser) and runs
them through lowering and codegen. Validates IR well-formedness after
each lowering pass.

```bash
perl fuzz/fuzz_ast.pl                          # 1000 iterations
perl fuzz/fuzz_ast.pl --iterations=5000 --verbose
```

**Properties checked:**
- IR well-formedness (label refs, balanced enter/leave, stack height, types)
- Lowering consistency (AST function names appear as IR labels)
- Codegen succeeds on well-formed IR
- AST size invariants (non-zero, bounded)

### `fuzz_tokens.pl` — Token stream mutation fuzzer

Lexes valid Brocken source, then mutates the token stream (insert, remove,
replace, swap, duplicate, corrupt) before feeding to the parser. Also
generates purely random token sequences.

```bash
perl fuzz/fuzz_tokens.pl                       # 1000 iterations
perl fuzz/fuzz_tokens.pl --iterations=10000
```

**Mutation strategies:**
- Clean lex (seed source)
- Insert/remove/replace/swap tokens
- Corrupt token values (NUM, VAR, IDENT)
- Purely random token sequences
- Random source → lex → parse

### `fuzz_semantic.pl` — Semantic integrity fuzzer

Generates random programs, compiles them with the full pipeline, runs the
resulting binary, and checks the exit code. Catches miscompilations and
runtime crashes.

```bash
perl fuzz/fuzz_semantic.pl                     # 100 iterations (compilation is slow)
perl fuzz/fuzz_semantic.pl --iterations=500 --verbose --keep
```

**Checks:**
- Compilation succeeds (no internal errors)
- Binary links and runs (no segfaults)
- Exit code is 0 or 42 (sensible values)

### `fuzz_check_ir.pl` — IR well-formedness validator

Targeted checker that generates IR sequences (from seeds, mutations, and
random generation) and validates them against structural rules. Tracks
which violations occur and their frequency.

```bash
perl fuzz/fuzz_check_ir.pl                     # 500 iterations
perl fuzz/fuzz_check_ir.pl --iterations=2000 --verbose
```

**Validation rules:**
- All jump targets reference existing labels
- `enter_func`/`leave_func` are balanced
- `shadow_push`/`shadow_get` stack height matches
- Arithmetic ops have correct argument counts
- No dead code after unconditional jumps
- Virtual registers are defined only once

## Library Modules

### `fuzz/lib/Fuzz/Check.pm`

IR well-formedness checker. Exports:

- `check_ir($ir)` — Returns arrayref of errors, or undef
- `is_well_formed($ir)` — Boolean shortcut
- `check_lowering($ast, $ir)` — AST/IR consistency
- `check_ir_properties($ir)` — Summary statistics

### `fuzz/lib/Fuzz/AST.pm`

Random AST generator for property-based testing. Exports:

- `random_program()` — Full program AST
- `random_expr()`, `random_stmt()` — Individual nodes
- `ast_size($node)` — Node count
- `count_nodes($node, $class)` — Count by type
- `ast_equals($a, $b)` — Structural equality

### `fuzz/lib/Fuzz/PrettyPrint.pm`

AST-to-source pretty-printer for round-trip testing. Exports:

- `ast_to_source($node)` — Reconstruct Brocken source from AST

## Seed Cases

The `cases/` directory contains known-good IR sequences:

- `001_arith.json` — basic arithmetic operations
- `002_control.json` — control flow (jmp, cond_br, label)
- `003_memory.json` — memory operations (load, store, local)
- `004_calls.json` — function calls and register args
- `005_edge.json` — edge cases (negative, zero, large values)

## Crash Triage

When any fuzzer finds a crash:

1. It logs the crashing input to `crashes.log`
2. Creates a replay script `replay.pl` for reproducing
3. The crash is classified:
   - **`CRASH`** — uncaught exception (die)
   - **`PANIC`** — assertion failure or internal error
   - **`OOM`** — out of memory / runaway allocation
   - **`TIMEOUT`** — exceeded iteration time limit
