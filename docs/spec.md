# The Brocken Language Specification

## 0. About
This is version 0.01 of the Brocken spec. I'm still sorting it out.

## 1. Philosophy & Overview
Brocken is a statically/dynamically typed, AOT compiled language designed for systems programming, scripting, and web environments. It borrows the text-processing power and expressiveness of Perl but removes its historical ambiguity. It utilizes strict invariant sigils, built-in cooperative multitasking (Fibers), a fast Mark-Region GC, and modern Object-Oriented features.

When executing dynamic code at runtime, Brocken embeds its AOT compiler to act as a Just-In-Time (JIT) engine, generating native machine code directly into memory.

## 2. Lexical Structure & Core Types

### 2.1 Comments & Documentation
*   `#` - **Single-line comment**: Ignores everything until the end of the line.
*   **POD6**: Plain Old Documentation v6. Brocken uses standard POD6 block markers (`=begin pod` / `=end pod`) for multi-line, structured documentation capable of generating HTML/man pages natively.

### 2.2 Variables & Invariant Sigils
Brocken uses **invariant sigils**. The symbol at the start of a variable never changes, regardless of how you access it.
*   `$` - **Scalar/Object**: A single value, reference, or object. (e.g., `$name`, `$user`).
*   `@` - **Array/List**: An ordered sequence of values. Indexed as `@items[0]` (not `$items[0]`).
*   `%` - **Hash/Dictionary**: Key-value pairs. Accessed as `%map{"key"}` (not `$map{"key"}`).

### 2.3 Built-in Types
Brocken supports gradual typing. If a type is omitted, it defaults to `Any`.
*   `Int`: 64-bit signed integer.
*   `String`: Immutable, UTF-8 encoded text.
*   `Bool`: Boolean type. Only accepts the built-in literal keywords `true` (1) and `false` (0).
*   `Array`: Dynamic list of values.
*   `Hash`: Key-value map.
    ```perl
        my @people = Array[isa Person];
        my %workers = Hash[ Int => Array[isa Person] ];
    ```
*   `Any`: A dynamically-resolved, tagged pointer.
*   `Class`: A metadata reference to an Object's blueprint.

---

## 3. Variable Scoping & Declarations

*   `my` - Declares a lexically scoped variable, restricted to the enclosing `{ ... }` block.
    *   *Usage*: `my Int $x = 10;`
*   `our` / `ours` - Declares a package/module-scoped global variable accessible from anywhere.
*   `local` - Temporarily overrides the value of an existing global variable for the duration of the current block, restoring the original value when the scope exits.
*   `state` - Declares a lexically scoped, persistent variable. It is initialized only once and retains its value across multiple function calls or fiber yields.
    *   *Usage*: `state Int $count = 0; $count++;`
*   `const` - Declares a compile-time constant. Its value can never be mutated.
    *   *Usage*: `const $pi = 3.14159;`
*   `type` - Creates a type alias for cleaner code.
    *   *Usage*: `type UserID = Int; my UserID $id = 42;`

---

## 4. Operators

### 4.1 Arithmetic & Assignment
*   `+`, `-`, `*`, `/`: Standard addition, subtraction, multiplication, and division.
*   `%`: Modulo (remainder of division).
*   `**`: Exponentiation.
*   `=`: Assignment.

### 4.2 Comparison (Numeric vs. String)
Like Perl, Brocken explicitly separates numeric math from string evaluation to prevent unsafe implicit coercion.
*   **Numeric:** `==` (Equal), `!=` (Not eq), `<` (Less), `>` (Greater), `<=` (Less/eq), `>=` (Greater/eq).
*   **Numeric Spaceship (`<=>`):** Returns `-1`, `0`, or `1` depending on if the left is less, equal, or greater than the right.
*   **String:** `eq` (Equal), `ne` (Not eq), `lt` (Less), `gt` (Greater), `le` / `leq` (Less/eq), `ge` / `geq` (Greater/eq).
*   **String Compare (`cmp`):** String equivalent of the spaceship operator.

### 4.3 Logical Operators
*   `&&`, `||`, `!`: High-precedence Short-circuiting AND, OR, and NOT.
*   `//` (Defined-OR): Returns the left side if it is defined; otherwise, returns the right side. Crucial for setting defaults: `my $port = $config_port // 8080;`
*   `and`, `or`, `not`, `xor`: Low-precedence logical operators. Typically used for control flow (e.g., `open(...) or die "Failed";`).

### 4.4 Bitwise Operators
*   `&` (AND), `|` (OR), `^` (XOR), `~` (NOT), `<<` (Left Shift), `>>` (Right Shift).

### 4.5 Misc Operators
*   `..` (Inclusive Range): `1..5` yields `[1, 2, 3, 4, 5]`.
*   `...` (Exclusive Range): `1...5` yields `[1, 2, 3, 4]`.
*   `->`: Method invocation or anonymous function call. `User->new()` or `$anon_sub->()`.
*   `=>`: Fat comma. Used for declaring Hash keys and values cleanly: `%h = (name => "Alice");`
*   `? :` (Ternary): Inline if/else expression. `my $status = $ok ? "Yes" : "No";`

---

## 5. Control Flow

### 5.1 Branching
*   `if` / `elsif` / `else`: Standard conditional execution blocks.
*   `unless`: The opposite of `if`. Executes only if the condition is false.
    *   *Usage*: `unless ($is_admin) { die "Forbidden"; }`
*   **Postfix Modifiers**: `if` and `unless` can be appended to single statements for readability.
    *   *Usage*: `say "Hello" if $greet;`
*   `do`: Evaluates a block and returns the value of the last evaluated expression.
*   `goto`: Jumps execution to a labeled section of code. Restricted to local scopes (cannot jump into or out of functions).

### 5.2 Strict Pattern Matching
*   `given`, `when`, `default`: A strictly-typed pattern matching construct.
    *   If `when` takes a value (`when(42)`), it uses strict equality (`==` or `eq`).
    *   If `when` takes a Type (`when(Int)`), it performs a type-check.
    *   If `when` takes a Regex (`when(qr/abc/)`), it performs a regex match.
    *   *Usage*:
        ```perl
        given ($status_code) {
            when (200) { say "OK"; }
            when (400..499) { say "Client Error"; }
            default { say "Unknown"; }
        }
        ```

### 5.3 Loops
*   `while`: Executes a block as long as the condition is true.
*   `until`: Executes a block as long as the condition is false. (Postfix: `$x++ until $x == 10;`)
*   `for` / `foreach`: Iterates over an array, range, or list.
    *   *Usage*: `for @items -> $item { say $item; }`

### 5.4 Loop Modifiers
*   `next`: Skips the remainder of the current loop body and proceeds to the next iteration.
*   `last`: Immediately breaks out of the loop entirely.
*   `redo`: Restarts the current loop iteration from the top without re-evaluating the loop condition.

---

## 6. Functions, Closures, & Concurrency

### 6.1 Subroutines
*   `sub`: Declares a named global function or an anonymous closure.
*   `return`: Exits the function, passing the evaluated expression back to the caller.

### 6.2 Fibers & Isolates
Brocken treats cooperative multitasking as a first-class language feature.
*   `fiber`: Spawns a lightweight, green thread with its own independent stack and shadow-stack for precise Garbage Collection.
*   `yield`: Pauses the execution of the current fiber, saving its state, and returning control (and an optional value) to the caller.
*   `transfer($fiber_handle, expr)`: Resumes a fiber, optionally passing a value into it.

    ```perl
    my Any $gen = fiber {
        say "Fiber started";
        yield 42;
        say "Fiber resumed";
        return 99;
    };

    my Int $res1 = transfer($gen, 0); # returns 42
    my Int $res2 = transfer($gen, 0); # returns 99
    ```

*   `isolate`: Spawns a fully isolated execution context (OS thread on x64 and ARM). Memory cannot be shared between isolates without explicit serialization.

### 6.3 Code Loading & Meta-Programming
Because Brocken is AOT compiled, it must distinguish between compile time dependency resolution and runtime dynamic loading.

*   `use` **(Compile-Time Import):**
    Parses and merges an external Brocken file or module into the current compilation unit *during compilation*. It allows the compiler to know about external types, classes, and macros.
    *   *Usage:* `use HTTP::Server;`
    *   *Behavior:* The compiler halts the current file, parses `HTTP::Server`, injects its symbols into the global scope, and compiles them together into a single binary/Wasm module.
*   `require` **(Runtime Code Loading):**
    Executes a Brocken file dynamically at runtime. Because it happens at runtime, it relies on the embedded JIT compiler (`eval` under the hood) to compile the file into memory and execute it.
    *   *Usage:* `require "config.brocken";`
    *   *Behavior:* Returns the last evaluated expression of the loaded file.
*   `load_module` **(Native FFI / Shared Library):**
    Loads a compiled C/C++/Rust shared object (`.so`, `.dll`, `.dylib`) or a WebAssembly import object into the Brocken runtime. This is the Foreign Function Interface (FFI).
    *   *Usage:* `my $lib = load_module("libcrypto.so");`
*   `eval`: JIT-compiles and executes a string of Brocken code at runtime.
    *   *Usage*: `eval "say 'Hello from JIT';";`

---

## 7. Exceptions & Cleanup

*   `try`: Opens a block to attempt dangerous execution.
*   `catch`: Catches exceptions thrown in a `try` block, assigning the error to a variable (e.g., `catch ($err)`).
*   `finally`: Executes after a `try/catch` block finishes, regardless of success or failure.
    ```perl
    try {
        # 'die' for fatal panic, or throw exceptions
        die "Fatal system error";
    } catch ($e) {
        carp "Warning: $e";
    } finally {
        # Always executes
    }
    ```
*   `throw`: Raises a catchable exception.
*   `defer`: Pushes a block of code onto a Last-In-First-Out (LIFO) stack. When the current lexical scope exits (for *any* reason-return, throw, or natural exit), the deferred blocks are executed. Excellent for resource management.
    *   *Usage*: `my $file = open("data.txt"); defer { close($file); }`

---

## 8. Object-Oriented Programming

*   `class`: Defines a new Object blueprint.
*   `role`: Defines a trait or mixin that can be composed into a class.
*   `method`: Defines a function attached to a class/role. Automatically injects a `$self` reference.
*   `has` / `field`: Declares state variables bound to the object instance.
*   **Attributes (`:`)**: Metadata attached to classes or variables.
    *   `:isa(Parent)` - Declares inheritance.
    *   `:does(Role)` - Composes a role into the class.
*   **Lifecycle Hooks**:
    *   `new`: Instantiates the object. Handled by the runtime, but can be overridden.
    *   `ADJUST`: An implicit method called immediately after `new` to initialize field values.
    *   `DESTROY`: Called exactly when the Garbage Collector reclaims the object.

---

## 9. Core Standard Library

*(The functions below are intrinsically recognized by the semantic analyzer and operate natively without needing `require`.)*

### 9.1 Introspection & State
*   `typeof($var)`: Returns the string/type object of the variable.
*   `sizeof($var)`: Returns the memory size of the target in bytes.
*   `cast($var, Type)`: Explicitly coerces a variable to a different type.
*   `defined($var)`: True if the variable holds a value other than undef.
*   `undef`: Keyword representing an uninitialized or null value.
*   `exists(%hash{"key"})`: True if the specific key exists in a hash.
*   `delete(%hash{"key"})`: Removes a key/value pair from a hash.
*   `is_const($var)`: Returns true if the variable's memory space is marked read-only.
*   `isa($obj, "Class")`: True if the object inherits from the class.
*   `does($obj, "Role")`: True if the object consumes the role.
*   `can($obj, "method_name")`: True if the object implements the given method.

### 9.2 Lists & Hashes
*   `push`, `pop`: Add/Remove from the end of an array.
*   `unshift`, `shift`: Add/Remove from the beginning of an array.
*   `map`, `grep`: Transform or filter an array iteratively.
*   `first`, `any`, `all`: Array interrogation.
*   `zip`: Combines multiple arrays element-by-element.
*   `count`, `reverse`, `sort`, `shuffle`: Array mutation/query functions.
*   `keys`, `values`, `pairs`, `each`: Interrogates Hash data.

### 9.3 Regular Expressions
*   `m//`: Match operator. Returns true if the regex matches.
*   `s///`: Substitution operator. Replaces matched text.
*   `tr///`: Transliteration operator. Swaps individual characters.
*   `qr//`: Compiles a regular expression object for later use.

### 9.4 Strings
*   `length`, `substr`, `index`, `rindex`: Standard string interrogation.
*   `split`, `join`: Break strings into arrays, or combine arrays into strings.
*   `chomp`, `chop`: Removes trailing newlines or trailing characters.
*   `trim`, `truncate`: Removes whitespace or cuts strings to a fixed length.
*   `uc`, `lc`, `ucfirst`: Uppercase, Lowercase, Uppercase-First.
*   `tc` (Title Case), `cc` (Camel Case): Advanced formatting.
*   `chr`, `ord`: Convert ASCII/UTF-8 integers to characters and vice versa.
*   `sprintf`: Formats a string using placeholders (e.g., `%d`, `%s`).
*   `quotemeta`: Escapes regex-sensitive characters in a string.
*   `vec`, `pack`, `unpack`: Binary and byte-level manipulation.

### 9.5 System, I/O & Time
*   `say`, `print`: Output to STDOUT (with and without a trailing newline).
*   `open`, `close`, `read`, `sysread`, `syswrite`, `slurp`: File handle manipulation and reading.
*   `opendir`, `readdir`, `closedir`, `mkdir`, `rm`, `rename`: File system manipulation.
*   `cwd`, `chdir`, `rel2abs`, `abs2rel`, `path`: Path operations.
*   `stat`, `flock`, `ioctl`, `eof`, `fileno`: Low-level system file operations.
*   `tempdir`, `tempfile`: Secure temporary creation.
*   `time`, `localtime`, `gmtime`, `utctime`, `alarm`: Time tracking and signals.
*   `fork`, `waitpid`, `system`, `kill`: Process execution and management.
*   `pid`, `tid`, `fid`: Returns the ID of the current Process, Thread, or Fiber.
*   `accept`, `connect`, `listen`, `bind`, `recv`: Native socket operations.

### 9.6 Math
*   `abs`: Absolute value.
*   `atan2`: Arc tangent.
*   `rand`, `srand`: Random number generation and seeding.

---

## 10. Native Unit Testing
Brocken has a native testing framework built directly into the compiler. Using a specific execution flag (e.g., `brocken --test`), the runtime evaluates the following directives to produce TAP (Test Anything Protocol) output.

*   `plan(Int)`: Declares how many tests are expected to run.
*   `ok(Bool, String)`: Passes if the condition is true.
*   `is($a, $b, String)`: Passes if `$a eq $b` or `$a == $b`.
*   `isa_ok($obj, "Class")`: Passes if the object matches the type.
*   `fail(String)`: Unconditionally fails a test.
*   `subtest(String, Sub)`: Groups multiple tests under a single isolated block.
*   `todo(String)`: Marks a test as expected to fail due to pending implementation.
*   `skip(String)`: Bypasses a test block entirely.
*   `dies(Sub)`: Passes if the provided code block throws an exception.
*   `bail(String)`: Aborts the entire test suite immediately.

```perl
plan 3;

subtest "Math checks", ->() {
    ok(1 + 1 == 2, "Addition works");
    is(abs(-5), 5, "Absolute value");
};

my $obj = User->new();
isa_ok($obj, "User");

try {
    fail("This forces a failure");
}

```
