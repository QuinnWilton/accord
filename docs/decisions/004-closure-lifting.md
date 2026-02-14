# ADR-004: closure lifting for serializable IR

## Status

Accepted

## Context

The accord DSL allows users to write anonymous functions for guards, updates, invariants, action properties, and forbidden checks:

```elixir
guard fn {:bet, chips}, tracks -> chips <= tracks.balance end
update fn msg, reply, tracks -> %{tracks | balance: tracks.balance - elem(msg, 1)} end
invariant fn tracks -> tracks.balance >= 0 end
```

These functions are captured during macro expansion. At that point, the Elixir compiler is running inside a temporary module named `elixir_compiler_N` (where N is incremented each compilation). The anonymous function's internal representation (NEW_FUN_EXT in the external term format) encodes a reference to this temporary module.

The IR is serialized with `term_to_binary` and stored as a module attribute (`@accord_ir_bin`). When the compiled `.beam` file is loaded in a later VM session, `binary_to_term` attempts to reconstruct the anonymous functions, but the `elixir_compiler_N` module no longer exists. The deserialization fails.

## Decision

Before serialization, `lift_closures/2` in `Accord.Protocol` walks the IR and replaces every anonymous function with a named function capture. For each closure:

1. A unique name is generated: `__accord_fn_0__`, `__accord_fn_1__`, etc.
2. The closure's AST is preserved from the original macro expansion.
3. The anonymous function reference is replaced with `Function.capture(Module, name, arity)`, which serializes as EXPORT_EXT (an MFA reference) rather than NEW_FUN_EXT.
4. The AST is compiled into a `def` clause in the protocol module by `fn_to_defs/1`.

The lifting handles guards on fn clauses (the `when` syntax) by extracting guard expressions and rewriting them as `def ... when guard` clauses.

Each closure is stored as a `%{fun: capture, ast: ast}` pair so the runtime uses the named capture while the TLA+ pipeline can inspect the original AST if needed.

## Consequences

**Positive:**

- The IR survives serialization and deserialization across VM sessions. The `.beam` file is self-contained.
- Named function captures are inspectable: `&MyProtocol.__accord_fn_0__/2` is visible in stack traces, unlike `#Function<N.M/2 in :elixir_compiler_5>`.
- The approach is invisible to users. They write anonymous functions in the DSL; the lifting happens automatically during `@before_compile`.

**Negative:**

- The protocol module gains `@doc false` functions (`__accord_fn_N__`) that are implementation details but appear in the module's function list.
- The lifting logic must handle all closure sites (guards, updates, branch constraints, invariants, action properties, forbidden checks). Missing a site causes a runtime crash on deserialization.
- Guard expressions in fn clauses require special AST manipulation (`extract_fn_guard/1`), adding complexity to the lifting code.
