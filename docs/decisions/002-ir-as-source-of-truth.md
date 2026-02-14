# ADR-002: single IR as source of truth for both pipelines

## Status

Accepted

## Context

Accord has two consumers of the protocol definition: the runtime monitor (downward pipeline) and the TLA+ model checker (upward pipeline). These consumers have different needs -- the monitor needs a fast transition lookup table and track initialization, while TLA+ needs a state space, action definitions, and temporal property expressions.

Two approaches were considered:

- **Separate representations** -- the DSL emits one structure optimized for runtime and another for verification. This risks the two representations diverging, meaning the TLA+ model might check properties that don't match what the monitor actually enforces.
- **Single intermediate representation** -- the DSL emits one canonical IR that both pipelines consume. Each pipeline transforms the IR into its own specialized form, but the source data is shared.

The core risk is semantic drift: if the runtime monitor enforces one set of transitions and the model checker verifies a different set, the formal guarantee is meaningless. A bug where a transition is present in one representation but absent from the other would silently invalidate the verification.

## Decision

A single `Accord.IR` struct is the canonical representation of the protocol. It contains states, transitions, branches, tracks, properties, and metadata. Both pipelines read from this same struct:

- The **downward pipeline** transforms the IR into a `TransitionTable` (flat map keyed by `{state, message_tag}`) and a `track_init` map. These are bundled into `Monitor.Compiled` for runtime use.
- The **upward pipeline** transforms the IR through `BuildStateSpace`, `BuildActions`, `BuildProperties`, and `Emit` passes to produce `.tla` and `.cfg` files.

Validation passes (`ValidateStructure`, `ValidateTypes`, `ValidateDeterminism`, `ValidateReachability`, `ValidateProperties`, `ResolveFieldPaths`) run on the IR before either pipeline consumes it, ensuring both pipelines receive a well-formed, validated structure.

## Consequences

**Positive:**

- The TLA+ specification models exactly what the runtime monitor enforces. If TLC finds no violations, the runtime monitor will not find them either (within the checked state space).
- Validation passes apply universally. A structural error caught during compilation prevents both broken runtime monitoring and incorrect TLA+ output.
- Adding a new feature (e.g., a new check kind) requires updating the IR once, then teaching each pipeline how to handle it.

**Negative:**

- The IR must accommodate both consumers, which occasionally means carrying fields that only one pipeline uses (e.g., `span` metadata is irrelevant to TLA+ emission but present on every node).
- Changes to the IR can have cascading effects across both pipelines. A structural change requires updating the transition table builder, the TLA+ passes, and potentially the validation passes.
- The IR serialization (via `term_to_binary`) must handle all node types correctly, which led to the closure lifting requirement (see ADR-004).
