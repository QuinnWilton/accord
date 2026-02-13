# accord2

Runtime protocol contracts for Elixir with blame assignment and TLA+ model checking.

## What it does

Accord lets you declare a state machine protocol (states, transitions, message types, reply types, guards, tracks, properties) using a compile-time DSL. At compile time, it:

1. Builds an intermediate representation (IR) from the DSL.
2. Validates the IR through a pipeline of passes.
3. Generates a runtime monitor (gen_statem proxy) that checks messages at runtime.
4. Generates a TLA+ specification for exhaustive model checking with TLC.

## Architecture

The IR (`Accord.IR`) is the single source of truth. Two pipelines flow from it:

- **Downward (runtime)**: IR → transition table + track init → `Accord.Monitor` (gen_statem)
- **Upward (verification)**: IR → state space → actions → properties → TLA+ `.tla` + `.cfg`

### Key modules

| Module | Responsibility |
|--------|---------------|
| `Accord.Protocol` | DSL macros, `@before_compile` orchestration |
| `Accord.IR` | IR structs (State, Transition, Branch, Track, Property, Check) |
| `Accord.Monitor` | Runtime gen_statem proxy with blame assignment |
| `Accord.Pass.*` | Validation passes (structure, types, determinism, reachability, properties, field paths, span refinement) |
| `Accord.Pass.Helpers` | Shared helpers for validation passes |
| `Accord.Pass.TLA.*` | TLA+ compilation passes (BuildStateSpace, BuildActions, BuildProperties, Emit) |
| `Accord.TLA.Compiler` | Orchestrates TLA+ pass pipeline |
| `Accord.TLA.TLCParser` | Parses TLC stdout into structured results |
| `Accord.TLA.ModelConfig` | Resolves finite domains for TLC model checking |
| `Accord.Type.Check` | Runtime type checking for messages and replies |
| `Accord.Violation` | Violation structs with blame (client/server/property) |

### Closure lifting

Guards, updates, invariants, and other user-provided functions are anonymous closures at macro expansion time. They reference the temporary `elixir_compiler_N` module, which doesn't exist at runtime. `lift_closures/2` in `Accord.Protocol` replaces each closure with a named function capture (`&Module.__accord_fn_N__/arity`) so they serialize correctly via `term_to_binary`.

## Development commands

```bash
mix test                      # run all tests
mix test test/accord/         # run unit tests
mix test test/property/       # run property-based tests
mix format                    # format code
mix format --check-formatted  # check formatting
mix dialyzer                  # static analysis
```

## Testing conventions

- Unit tests mirror `lib/` structure in `test/accord/`.
- Property-based tests (propcheck statem) live in `test/property/`.
- Test support modules (protocols, faulty servers) in `test/support/`.
- Test helpers build IR structs directly with `sample_ir` functions.
- Use `@moduletag :capture_log` for tests that trigger logged violations.
- Use `:sys.get_state/1` as a synchronous barrier instead of `timer.sleep`.

## Patterns to know

- `Accord.Pass.Helpers` provides shared `maybe_add_source/2`, `maybe_add_span_label/3`, and `message_tag/1` for validation passes. Import it rather than duplicating.
- The `message_tag/1` in `Monitor` and `TransitionTable` operates on raw runtime messages (atoms/tuples) — semantically different from the IR helpers version.
- Validation passes return `{:ok, ir}` or `{:error, [Report.t()]}`. The compiler pipeline in `Protocol.compile_ir/2` chains them with `with`.
- TLA+ passes return `{:ok, result}` and are orchestrated by `TLA.Compiler.compile/2`.
