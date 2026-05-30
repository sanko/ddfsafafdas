# NAME

Brocken - Top-level package for the Brocken compiler

# SYNOPSIS

```perl
use Brocken;
```

# DESCRIPTION

Loads all compiler components and defines base types used throughout:

- Brocken::Symbol

    Metadata for a single variable: name, type, is\_state, state\_idx, stack\_offset.

- Brocken::Scope

    Lexical scope with parent chain. `define()` registers a symbol (dies on redeclaration). `resolve()` looks up a symbol
    in the current scope and walks up the parent chain.

# POD ERRORS

Hey! **The above document had some coding errors, which are explained below:**

- Around line 36:

    &#x3d;over without closing =back
