# Task examples for accord2

This document contains four well-specified task examples that demonstrate how to write tasks for the accord2 codebase. Each example covers a different type of work. Use these as templates.

---

## Task 1: Add a validation pass for duplicate track names

### Context

The `track` DSL macro allows declaring named accumulators that persist across transitions. Currently, nothing prevents a user from declaring two tracks with the same name. If this happens, the second declaration silently shadows the first, leading to confusing runtime behavior where the initial value or type of a track depends on declaration order. Other structural issues (missing initial state, undefined goto targets) are already caught by `Accord.Pass.ValidateStructure`.

### Acceptance criteria

1. A new module `Accord.Pass.ValidateTracks` exists at `lib/accord/pass/validate_tracks.ex`.
2. The pass exports `run/1` with the spec `@spec run(IR.t()) :: {:ok, IR.t()} | {:error, [Report.t()]}`.
3. When two or more tracks share the same name, the pass returns an error report with:
   - A message containing `"duplicate track name :#{name}"`.
   - Error code `"E040"`.
   - A primary span label on the second (duplicate) declaration.
   - A secondary span label on the first declaration, with the text `"first defined here"`.
   - A help hint.
4. When all track names are unique, the pass returns `{:ok, ir}`.
5. The pass is wired into the `compile_ir/2` pipeline in `Accord.Protocol`, running after `ValidateStructure` and before `ValidateTypes`.
6. All existing tests continue to pass.

### Files to read first

- `lib/accord/pass/validate_structure.ex` -- simplest validation pass, shows the return convention, error accumulation pattern, and how to use `Accord.Pass.Helpers`.
- `lib/accord/pass/validate_determinism.ex` -- shows how to attach multiple span labels (primary and secondary) to a single report.
- `lib/accord/pass/helpers.ex` -- shared helpers to import.
- `lib/accord/ir.ex` -- the `tracks` field on the IR struct.
- `lib/accord/ir/track.ex` -- the `Track` struct with `name` and `span` fields.
- `lib/accord/protocol.ex` -- the `compile_ir/2` function that chains passes with `with`.

### Files to modify

- `lib/accord/pass/validate_tracks.ex` (new file).
- `lib/accord/protocol.ex` -- add the new pass to the `compile_ir/2` pipeline.
- `test/accord/pass/validate_tracks_test.exs` (new file).

### Testing requirements

- Create `test/accord/pass/validate_tracks_test.exs` with `async: true`.
- Define a `base_ir/0` helper that builds a minimal valid IR with one track.
- Test cases:
  - Accepts IR with unique track names.
  - Accepts IR with no tracks.
  - Rejects IR with two tracks sharing the same name; assert the error message, error code, and that the report has at least two labels.
  - Rejects IR with three tracks where two are duplicates; assert exactly one error report (not two).
- Run `mix test test/accord/pass/validate_tracks_test.exs`.
- Run `mix test` to confirm no regressions.

### Patterns to follow

- Error accumulation: `ValidateStructure` starts with `errors = []` and prepends errors, then reverses at the end. Follow the same pattern.
- Span labels: `ValidateDeterminism.check_state_determinism/3` shows how to attach `Label.primary` and `Label.secondary` to a single report using `Report.with_labels/2`.
- Helpers: import `Accord.Pass.Helpers` and use `maybe_add_source/2` and `maybe_add_span_label/3`.
- Error codes: structure-related passes use E0xx. The next available block is E040.
- Test helpers: build IR structs directly using `%IR{}`, `%Track{}`, etc., as all existing pass tests do.

---

## Task 2: Add a rate limit violation kind

### Context

The monitor currently detects several categories of protocol violations (invalid message, argument type mismatch, guard failure, session ended, invalid reply, timeout). There is no mechanism to detect when a client sends messages faster than the protocol allows. A new violation kind, `:rate_exceeded`, would let protocols specify a maximum message rate per state and have the monitor flag clients that exceed it. This task adds the violation struct constructor only; integrating it into the monitor's call pipeline is a separate task.

### Acceptance criteria

1. The `Accord.Violation` module gains a new public function `rate_exceeded/4` with the spec:
   ```elixir
   @spec rate_exceeded(atom(), term(), pos_integer(), pos_integer()) :: t()
   ```
   The arguments are `state`, `message`, `max_per_second`, and `actual_count`.
2. The returned violation has `blame: :client`, `kind: :rate_exceeded`, and a `context` map containing `:max_per_second` and `:actual_count`.
3. The `@type kind` union in `Accord.Violation` includes `:rate_exceeded`.
4. The `@moduledoc` documents the new kind under the "Client violations" section.
5. The `Inspect` implementation continues to work without changes (it only renders `blame`, `kind`, `state`, `message`, `expected`, and `reply`).
6. All existing tests continue to pass.

### Files to read first

- `lib/accord/violation.ex` -- the full module, including the struct definition, type specs, existing constructors, `@moduledoc`, and the `Inspect` implementation.
- `test/accord/monitor_test.exs` -- see how violations are created and asserted in existing tests.

### Files to modify

- `lib/accord/violation.ex` -- add the new kind to the type union, add the constructor function, update the `@moduledoc`.
- `test/accord/violation_test.exs` (new file, unless it already exists).

### Testing requirements

- Create `test/accord/violation_test.exs` with `async: true` if it does not already exist.
- Test cases:
  - `rate_exceeded/4` returns a violation with correct `blame`, `kind`, `state`, and `message` fields.
  - The `context` map contains `:max_per_second` and `:actual_count` with the values passed in.
  - `inspect/2` on the violation does not raise and produces a string containing `":rate_exceeded"`.
- Run `mix test test/accord/violation_test.exs`.
- Run `mix test` to confirm no regressions.

### Patterns to follow

- Constructor pattern: every existing constructor in `Accord.Violation` builds a `%__MODULE__{}` struct literal with hardcoded `blame` and `kind` values and a `context` map for extra data. Follow the same pattern. See `argument_type/5` for a client violation with a context map.
- Documentation: the `@moduledoc` lists violation kinds in bullet lists grouped by blame. Add `:rate_exceeded` to the "Client violations" group with a one-line description.
- Type union: the `@type kind` lists all atoms on separate lines. Add `:rate_exceeded` in the client section, after `:session_ended`.

---

## Task 3: Add a `timeout` option to the `on` keyword form

### Context

The `on` DSL macro currently supports `reply:` and `goto:` options in its keyword form. There is no way to specify a per-transition call timeout. The monitor uses a single `call_timeout` value (default 5000ms) for all upstream calls. Adding a `timeout:` option to the keyword form would allow protocol authors to specify different timeouts for different transitions (for example, a fast ping vs. a slow batch operation). This task adds the DSL keyword and stores the value in the IR; wiring it into the monitor's `forward_call/5` is a separate task.

### Acceptance criteria

1. The `on` keyword form accepts an optional `timeout:` key:
   ```elixir
   on :slow_op, reply: {:ok, term()}, goto: :ready, timeout: 30_000
   ```
2. The `Accord.IR.Transition` struct gains a new field `call_timeout` with a default of `nil`.
3. When `timeout:` is provided, the transition's `call_timeout` field is set to the integer value.
4. When `timeout:` is omitted, the transition's `call_timeout` field remains `nil`.
5. The `@type t` on `Transition` includes `call_timeout: pos_integer() | nil`.
6. The block form of `on` also supports `timeout` via a new block-level macro (similar to `reply`, `goto`, `guard`, `update`).
7. All existing tests continue to pass. Existing protocols that do not use `timeout:` are unaffected.

### Files to read first

- `lib/accord/protocol.ex` -- the `on/2` macro for both keyword and block forms. Understand how `reply:` and `goto:` are parsed in the keyword form and how module attributes are used in the block form.
- `lib/accord/protocol/block.ex` (if it exists) -- block-level macros like `reply`, `goto`, `guard`, `update`.
- `lib/accord/ir/transition.ex` -- the `Transition` struct and its type spec.
- `test/support/` -- example protocol modules used in integration tests.

### Files to modify

- `lib/accord/ir/transition.ex` -- add `call_timeout` field and update `@type t`.
- `lib/accord/protocol.ex` -- parse `timeout:` in the keyword form of `on/2`, thread it into the `%Transition{}`.
- `lib/accord/protocol/block.ex` (if it exists) -- add a `timeout` block-level macro.
- `test/accord/protocol_test.exs` or a new `test/accord/protocol/timeout_test.exs`.

### Testing requirements

- Test that compiling a protocol with `timeout: 10_000` on a transition produces a `Transition` struct with `call_timeout: 10_000`. This can be tested by inspecting the compiled IR (the `__accord_ir__/0` function on the protocol module, or by building IR structs directly).
- Test that compiling a protocol without `timeout:` produces `call_timeout: nil`.
- Test the block form sets `call_timeout` correctly.
- Run `mix test` to confirm no regressions.

### Patterns to follow

- Keyword parsing: in `on/2` for the keyword form, `Keyword.get(opts, :reply)` extracts the reply type and `Keyword.get(opts, :goto)` extracts the target state. Add `Keyword.get(opts, :timeout)` in the same style.
- Block attributes: in the block form, each sub-keyword (reply, goto, guard, update) uses a module attribute like `@accord_on_reply_type`. Follow the same pattern: register `@accord_on_timeout`, set it in the block macro, read it after the block executes.
- Struct field: add `call_timeout` to `Transition`'s `defstruct` list with no `@enforce_keys` entry (it is optional). Add it to `@type t` as `call_timeout: pos_integer() | nil`.
- The `track` macro in `lib/accord/protocol.ex` (lines 121-139) shows the pattern for parsing a keyword option and threading it into an IR struct.

---

## Task 4: Fix anystate cast transitions ignored in terminal state check

### Context

The `ValidateStructure` pass checks that terminal states have no transitions (error E003). However, it only checks `state.transitions` -- the transitions declared directly inside the state block. It does not account for `anystate` transitions. This is correct behavior: anystate transitions are not copied into terminal states at the IR level, and the monitor already skips terminal states when dispatching anystate transitions.

The actual bug is different: `ValidateStructure.check_goto_targets/2` iterates over all transitions (including anystate) and checks that their `branch.next_state` targets exist in the state map. But when a state is defined with `state :done, terminal: true` (no block), the state's `transitions` list is `[]`. If an anystate transition uses `goto: :done`, this is valid. However, if the anystate block contains a transition that branches to a state that is not the atom `:__same__` and is not in the state map, the error message says "undefined state reference" but does not indicate that the transition came from `anystate`. This makes the error confusing to diagnose.

### Acceptance criteria

1. When `check_goto_targets/2` reports an undefined state reference from an anystate transition, the error message includes the phrase `"in anystate"` to distinguish it from a per-state transition error.
2. When the undefined reference comes from a per-state transition, the error message includes `"in state :#{state_name}"` to identify the source state.
3. The error code remains `"E002"`.
4. Existing tests that assert on the E002 error message are updated to match the new format.
5. A new regression test covers the anystate case specifically.
6. All existing tests continue to pass.

### Files to read first

- `lib/accord/pass/validate_structure.ex` -- the `check_goto_targets/2` function. Understand how it iterates over all transitions and branches.
- `test/accord/pass/validate_structure_test.exs` -- existing test for "rejects undefined goto target".

### Files to modify

- `lib/accord/pass/validate_structure.ex` -- modify `check_goto_targets/2` to track whether each transition came from a state or from anystate, and include that context in the error message.
- `test/accord/pass/validate_structure_test.exs` -- update the existing E002 test assertion if the message format changes, and add a new test for the anystate case.

### Testing requirements

- Update the existing `"rejects undefined goto target"` test to assert the message contains `"in state :ready"` (or whichever state the test IR uses).
- Add a new test `"rejects undefined goto target in anystate"` that:
  - Builds an IR with an anystate transition targeting `:nowhere`.
  - Asserts the error report message contains both `"undefined state reference :nowhere"` and `"in anystate"`.
- Add a test that a valid anystate transition targeting a declared state produces no error.
- Run `mix test test/accord/pass/validate_structure_test.exs`.
- Run `mix test` to confirm no regressions.

### Patterns to follow

- The existing `check_goto_targets/2` iterates `all_transitions` as a flat list, losing the distinction between state transitions and anystate transitions. Refactor to process them in two passes or tag each transition with its source before iterating. The simpler approach: iterate `states` transitions with `{:state, state_name}` context, then iterate `ir.anystate` with `:anystate` context.
- Error messages in this pass use `Report.error/1` with a descriptive string, then `Report.with_code/2`, `maybe_add_source/2`, and `maybe_add_span_label/3`. Maintain this chain and add the source context to the message string itself.
- Keep the error code as `"E002"` since this is the same class of error (undefined state reference), just with better context.
