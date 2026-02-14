# Architecture

This document describes the internal architecture of accord2. It exists so that
both humans and agents can understand design intent, dependency rules, and the
reasoning behind structural decisions.

## Two-pipeline architecture

The intermediate representation (`Accord.IR`) is the single source of truth.
Every DSL declaration compiles down to IR structs, and two independent pipelines
consume that IR for different purposes.

The downward pipeline produces a runtime monitor. The upward pipeline produces a
TLA+ specification for exhaustive model checking. Both pipelines read from the
same IR but never depend on each other.

```
                        +-------------------+
                        |   DSL (Protocol)  |
                        +--------+----------+
                                 |
                          @before_compile
                                 |
                        +--------v----------+
                        |     Accord.IR     |
                        |  (source of truth)|
                        +--------+----------+
                                 |
                 +---------------+---------------+
                 |                               |
         downward (runtime)              upward (verification)
                 |                               |
    +------------v-------------+   +-------------v-----------+
    | Pass.Monitor.            |   | Pass.TLA.BuildStateSpace |
    |   BuildTransitionTable   |   | Pass.TLA.BuildActions   |
    |   BuildTrackInit         |   | Pass.TLA.BuildProperties|
    +------------+-------------+   | Pass.TLA.Emit           |
                 |                 +-------------+-----------+
    +------------v-------------+                 |
    | Monitor.Compiled         |   +-------------v-----------+
    |   .transition_table      |   | .tla file  |  .cfg file |
    |   .track_init            |   +-------------------------+
    +------------+-------------+
                 |
    +------------v-------------+
    |   Accord.Monitor         |
    |   (gen_statem proxy)     |
    +--------------------------+
```

### Why two pipelines?

Runtime monitoring and formal verification have fundamentally different needs.
The monitor needs fast O(1) dispatch from `{state, message_tag}` pairs, so it
uses a flat lookup table. The TLA+ pipeline needs a complete state space
enumeration with existential quantification over domains, so it builds an
entirely different representation. Keeping them separate means neither pipeline
constrains the other's evolution.

### The IR in detail

The IR is a tree of structs rooted at `Accord.IR`:

- `IR` -- top level: name, initial state, roles, tracks, states, anystate, properties.
- `IR.State` -- a named state with transitions and optional terminal flag.
- `IR.Transition` -- a message handler: pattern, types, guard, update, branches.
- `IR.Branch` -- maps a reply type to a next state, with optional constraint.
- `IR.Track` -- a named accumulator with type and default value.
- `IR.Property` -- a named container for one or more checks.
- `IR.Check` -- an individual check: kind (invariant, action, liveness, etc.) and spec.
- `IR.Role` -- a participant declaration.
- `IR.Type` -- type representations parsed from the DSL.

Every IR node carries an optional `Pentiment.Span.t()` for diagnostics. The IR
depends on nothing internal to accord2 except pentiment for span types.

### Downward pipeline

`Protocol.build_compiled/1` drives the downward pipeline:

1. `Pass.Monitor.BuildTransitionTable.run/1` flattens the IR into a `{state, tag}` map,
   merging anystate transitions into every non-terminal state.
2. `Pass.Monitor.BuildTrackInit.run/1` produces a map of track names to default values.
3. The results are packaged into `Monitor.Compiled`, which the gen_statem reads
   at init time.

### Upward pipeline

`TLA.Compiler.compile/2` drives the upward pipeline:

1. `Pass.TLA.BuildStateSpace` produces VARIABLES, TypeInvariant, and Init from
   states, tracks, and roles. It resolves finite domains from ModelConfig.
2. `Pass.TLA.BuildActions` produces one TLA+ action per transition-branch pair.
   Guards compile to enabling conditions. Updates compile to primed assignments.
3. `Pass.TLA.BuildProperties` maps property checks to TLA+ formulas (invariants,
   temporal properties, action properties).
4. `Pass.TLA.Emit` renders the compiled structures into `.tla` and `.cfg` strings.

The TLA+ files are written to `_build/accord/` at compile time.

## Blame assignment semantics

When the monitor detects a protocol violation, it assigns blame to one of three
parties. The blame determines who is responsible for the contract breach and
drives how violations are reported and handled.

### :client blame

The client is blamed when it sends something that violates the protocol's
expectations. The monitor can detect this before forwarding to the server.

| Kind | When it fires |
|------|--------------|
| `:invalid_message` | The message tag is not valid in the current state. |
| `:argument_type` | A message argument fails its declared type constraint. |
| `:guard_failed` | The guard function returned false for this message and tracks. |
| `:session_ended` | The client sent a message after reaching a terminal state. |

Decision rule: if the monitor can reject the message before contacting the
server, the client is at fault. Client violations are caught at steps 1-2 of the
call pipeline (tag lookup, type check, guard evaluation).

### :server blame

The server is blamed when it returns something that violates the protocol's
reply contract. The monitor detects this after receiving the reply.

| Kind | When it fires |
|------|--------------|
| `:invalid_reply` | The reply does not match any branch's declared reply type. |
| `:timeout` | The server did not respond within the configured timeout. |

Decision rule: if the message was valid but the server's response was not, the
server is at fault. Server violations are caught at step 4 of the call pipeline
(reply type checking after `GenServer.call`).

### :property blame

Property violations indicate that the protocol's higher-level invariants have
been broken. These are not attributable to a single bad message or reply --
they reflect emergent behavior of the interaction.

| Kind | When it fires |
|------|--------------|
| `:invariant_violated` | A global or local invariant over tracks returned false. |
| `:action_violated` | A pre/post comparison on old and new tracks failed. |
| `:liveness_violated` | A liveness timer expired without reaching the target state. |
| `:precedence_violated` | Entered a state without the required predecessor in history. |
| `:ordering_violated` | A monotonicity check on message field values failed. |

Decision rule: property violations are reported after a successful transition.
The reply is still forwarded to the client (the transition succeeded), but the
violation is reported separately. This is because the individual message and
reply were both valid -- only the aggregate behavior broke the property.

### Violation policies

The monitor supports four policies that control what happens after a violation:

- `:log` -- log the violation, return `{:accord_violation, v}` to caller.
- `:reject` -- same as `:log` (violation is logged and returned).
- `:crash` -- stop the monitor process with `{:protocol_violation, v}`.
- `{mod, fun}` -- call a custom handler, then continue.

Property violations under `:log` and `:reject` forward the reply normally and
log the violation as a side effect. Under `:crash`, the reply is sent but the
monitor stops immediately after.

## Closure lifting

### The problem

When the DSL macros expand during compilation, guard functions, update functions,
invariants, and other user-provided closures are anonymous functions. Elixir
compiles these as `NEW_FUN_EXT` terms that reference the temporary
`elixir_compiler_N` module -- a module that exists only during compilation and
is discarded when compilation finishes.

The compiled IR needs to be serialized via `term_to_binary` (for the
`@accord_ir_bin` and `@accord_compiled_bin` module attributes) and deserialized
in later VM sessions. Anonymous closures that reference `elixir_compiler_N`
break on deserialization because that module no longer exists.

### The solution

`Protocol.lift_closures/2` walks the IR and replaces every anonymous closure
with a named function capture (`&Module.__accord_fn_N__/arity`). It collects the
original fn ASTs so they can be compiled as `def` clauses in the protocol module.

The process:

1. Walk all states, transitions, branches, and property checks.
2. For each `%{fun: closure, ast: ast}` pair, generate a unique name like
   `__accord_fn_0__`, `__accord_fn_1__`, etc.
3. Replace the anonymous closure with `Function.capture(module, name, arity)`.
4. Collect `{name, arity, ast}` triples.
5. `fn_to_defs/1` converts the collected fn ASTs into `def` clauses injected
   into the module via `unquote_splicing`.

The resulting function captures serialize as `EXPORT_EXT` (MFA references),
which are stable across VM sessions because they reference the protocol module
itself rather than a temporary compiler module.

### What gets lifted

- Transition guards (`guard` field)
- Transition updates (`update` field)
- Branch constraints (`constraint` field)
- Property check specs for: invariant, local_invariant, action, forbidden

## Pass pipeline design

### The validation contract

Every validation pass follows the same contract:

```elixir
@spec run(IR.t()) :: {:ok, IR.t()} | {:error, [Report.t()]}
```

A pass either returns the IR unchanged (or enriched) on success, or returns a
list of pentiment `Report` structs on failure. This uniform interface allows
passes to be composed with `with` chains.

### Pass ordering

`Protocol.compile_ir/2` chains the passes in a specific order. The ordering is
not arbitrary -- later passes depend on guarantees established by earlier ones.

```
RefineSpans           (1) Narrow coarse macro spans to specific tokens
    |
ValidateStructure     (2) IR is structurally well-formed
    |
ValidateTypes         (3) Type-level constraints hold (track defaults, branches)
    |
ValidateDeterminism   (4) No ambiguous (state, tag) dispatch
    |
ValidateReachability  (5) State graph connectivity (warnings only)
    |
ValidateProperties    (6) Property checks reference valid tracks/states/events
    |
ResolveFieldPaths     (7) Resolve by: field paths to tuple positions
```

Why this order matters:

- `RefineSpans` runs first because all subsequent passes benefit from precise
  span locations in their error reports.
- `ValidateStructure` must precede everything else because later passes assume
  states exist and goto targets are valid.
- `ValidateTypes` checks track defaults and branch presence, which
  `ValidateDeterminism` assumes are correct.
- `ValidateDeterminism` ensures unique `(state, tag)` dispatch, which
  `Monitor.BuildTransitionTable` relies on.
- `ValidateReachability` only produces warnings (never errors), so it does not
  block the pipeline.
- `ValidateProperties` validates that property check references (tracks, states,
  events) are valid before `ResolveFieldPaths` tries to look them up.
- `ResolveFieldPaths` runs last because it needs both validated properties and
  the full transition set.

### Chaining with `with`

The pipeline uses Elixir's `with` to short-circuit on the first failure:

```elixir
with {:ok, ir} <- Pass.RefineSpans.run(ir),
     {:ok, ir} <- run_pass(Pass.ValidateStructure, ir, env),
     {:ok, ir} <- run_pass(Pass.ValidateTypes, ir, env),
     ...
```

The `run_pass/3` helper wraps each pass to format errors as `CompileError` when
a pass returns `{:error, reports}`. It loads the source file, formats each
report through pentiment, and raises a `CompileError` with the formatted message.

### Pass helpers

`Accord.Pass.Helpers` provides shared functions that all validation passes use:

- `maybe_add_source/2` -- conditionally attach a source file path to a report.
- `maybe_add_span_label/3` -- conditionally attach a span with a label message.
- `message_tag/1` -- extract the message tag from an IR transition struct.
- `derive_arg_span/2` -- narrow a search span to a different pattern on the same
  line.

Passes import this module rather than duplicating these helpers. Note that
`message_tag/1` in `Pass.Helpers` operates on IR transition structs, while
`message_tag/1` in `Monitor` and `TransitionTable` operates on raw runtime
messages. They are semantically different despite the same name.

### TLA+ passes

The TLA+ passes follow a different contract:

```elixir
@spec run(IR.t(), ...) :: {:ok, result}
```

They always succeed (the validation passes have already ensured the IR is valid).
They are orchestrated by `TLA.Compiler.compile/2` rather than the main
validation pipeline. If TLA+ compilation fails (e.g., due to unsupported guard
AST), the failure is caught and logged as a warning rather than blocking
compilation.

## Error reporting architecture

### Pentiment integration

All error reporting flows through pentiment, the workspace's source span and
diagnostic library. Pentiment provides:

- `Pentiment.Span` -- source location types (Position with line/column,
  Search with line/pattern for deferred resolution).
- `Pentiment.Report` -- structured diagnostics with severity, message, code,
  labels, notes, and help text.
- `Pentiment.Label` -- primary and secondary source annotations.
- `Pentiment.Source` -- source file loading for rendering.
- `Pentiment.format/2` -- renders a report with source context into a string.

The DSL macros capture spans at macro expansion time using `span_ast/1` (which
reads `__CALLER__.line` and `__CALLER__.column`). The `RefineSpans` pass then
narrows these to point at specific tokens (state names, message tags) by
searching the source file.

### Error codes

Validation errors use a code scheme to identify the class of problem. This makes
it possible to search for documentation or suppress specific checks.

**Structure errors (E001-E003):**
- E001 -- initial state is not defined.
- E002 -- undefined state reference (goto target).
- E003 -- terminal state has transitions.

**Type errors (E010-E011):**
- E010 -- track default does not conform to declared type.
- E011 -- call transition has no branches (no reply type).

**Determinism errors (E020):**
- E020 -- ambiguous dispatch (multiple transitions for same state + tag).

**Property errors (E030-E036):**
- E030 -- bounded check references undefined track.
- E031 -- correspondence check references undefined open event.
- E032 -- local_invariant check references undefined state.
- E033 -- reachable check references undefined state.
- E034 -- precedence check references undefined target or required state.
- E035 -- field path references unknown event.
- E036 -- field not found in message parameters.

**Warnings (W001-W002):**
- W001 -- state unreachable from initial state.
- W002 -- no terminal state reachable from initial state.

### Help text

Every error report includes contextual help that suggests how to fix the problem.
For example, E001 lists the defined states, E002 lists valid goto targets, and
E036 lists available message parameters. This design ensures that error messages
are actionable -- the user does not need to look elsewhere to understand what
went wrong and how to fix it.

### Runtime violation reports

`Accord.Violation.Report` formats runtime violations as pentiment diagnostics.
When a `Compiled` struct is available, it looks up the relevant transition's
source span so the diagnostic points to the protocol definition. The span
lookup is violation-kind-aware:

- Guard failures point at the guard keyword, not the transition.
- Argument type violations point at the specific argument's type annotation.
- Invalid reply violations point at the reply type declaration.

A `:strict` option causes the formatter to raise on missing or invalid spans,
which is used in tests to catch span regressions early.

## Module dependency rules

The dependency graph is intentionally constrained. Violating these rules creates
coupling between pipelines that should remain independent.

### Core rule: the IR depends on nothing internal

`Accord.IR` and its sub-structs (`State`, `Transition`, `Branch`, `Track`,
`Property`, `Check`, `Role`, `Type`) depend only on pentiment for span types.
They never import or alias other accord modules. This ensures the IR remains a
stable, shareable data structure.

### Runtime pipeline isolation

The runtime modules (`Monitor`, `Monitor.Compiled`, `Monitor.TransitionTable`,
`Type.Check`, `Violation`) must NOT depend on any `Pass.TLA.*` module. The
runtime pipeline operates on the compiled transition table and IR properties --
it never needs TLA+ state spaces, actions, or emitted formulas.

### Validation passes depend on IR

All `Pass.*` modules depend on `Accord.IR` and `Pentiment.Report`. They import
`Pass.Helpers` for shared utilities. They do not depend on `Monitor`,
`Violation`, or TLA+ modules.

### TLA+ passes depend on IR and TLA structs

`Pass.TLA.*` modules depend on `Accord.IR`, `Accord.TLA.*` structs
(`StateSpace`, `Action`, `Property`, `ModelConfig`), and `TLA.GuardCompiler`.
They do not depend on `Monitor` or `Violation`.

### Protocol orchestrates everything

`Accord.Protocol` is the only module that touches both pipelines. It calls the
validation pass chain, the closure lifter, and the TLA+ compiler. It assembles
`Monitor.Compiled` via `build_compiled/1`. This is appropriate because
`Protocol` is a compile-time orchestrator, not a runtime dependency.

### Dependency summary

```
IR (depends on nothing internal)
  ^
  |--- Pass.* (validation passes)
  |--- Pass.TLA.* (TLA+ compilation passes)
  |--- Monitor, Monitor.Compiled, TransitionTable (runtime)
  |--- Violation, Violation.Report (error reporting)
  |--- Protocol (compile-time orchestration of everything)
```

No arrows cross between the runtime group and the TLA+ group. The IR is the
shared interface between them.
