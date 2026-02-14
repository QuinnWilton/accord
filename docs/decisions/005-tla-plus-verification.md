# ADR-005: TLA+ for model checking

## Status

Accepted

## Context

Runtime monitoring catches violations as they happen, but it only observes the executions that actually occur. To verify that a protocol has no violations in any reachable state, exhaustive exploration of the state space is needed.

Several approaches were considered:

- **Property-based testing only (QuickCheck/StreamData)** -- generates random sequences of operations and checks postconditions. Good at finding bugs quickly but provides no completeness guarantee. It may miss corner cases that require specific sequences of events.
- **Custom model checker** -- build a purpose-built state space explorer in Elixir. Full control over the exploration strategy, but requires implementing state hashing, symmetry reduction, liveness checking, and counterexample generation from scratch.
- **TLA+ with TLC** -- compile the protocol IR to a TLA+ specification and use the existing TLC model checker. TLC provides exhaustive breadth-first state space exploration, temporal property checking (safety and liveness), and detailed counterexample traces.
- **Alloy or other formal tools** -- relational logic with bounded model checking. Powerful for structural properties but less natural for stateful protocol specifications with explicit transitions.

The protocol IR already describes a finite state machine with explicit states, transitions, guards, and properties. TLA+ is a natural fit because it models systems as state machines with transition relations, and TLC can check both invariants and temporal properties (including liveness under fairness assumptions).

## Decision

The upward pipeline compiles the protocol IR to TLA+ through four passes orchestrated by `Accord.TLA.Compiler`:

1. **BuildStateSpace** -- derives TLA+ variables from protocol states and tracks. Uses `ModelConfig` to resolve finite domains for model checking (e.g., constraining `pos_integer()` to `1..3`).
2. **BuildActions** -- translates each transition into a TLA+ action with preconditions (state guard, type guard) and effects (state change, track updates).
3. **BuildProperties** -- converts protocol properties into TLA+ invariants, temporal formulas, and fairness conditions.
4. **Emit** -- renders the TLA+ module (`.tla`) and configuration file (`.cfg`) as strings.

The generated files are written to `_build/accord/` during compilation. Users run TLC externally against these files. The `TLCParser` module parses TLC's stdout back into structured results for integration into the development workflow.

## Consequences

**Positive:**

- Exhaustive verification within the configured state space bounds. If TLC reports no violations, every reachable state has been checked.
- Temporal properties (liveness, leads-to) are checked natively by TLC, which handles fairness constraints and cycle detection.
- TLA+ has a large ecosystem: the TLA+ toolbox, community specifications, and published literature on protocol verification.
- The generated `.tla` files are human-readable and can be manually inspected or extended by users familiar with TLA+.

**Negative:**

- TLC requires a JVM, adding a runtime dependency for verification (though not for the Elixir application itself).
- State space explosion limits the size of models that can be checked exhaustively. Users must configure finite domains carefully to keep the state space tractable.
- The translation from IR to TLA+ must be semantically faithful. A bug in the compiler passes could cause TLC to check a different system than what the runtime monitor enforces (mitigated by ADR-002's shared IR).
- Users who are unfamiliar with TLA+ may find the generated specifications difficult to interpret when TLC reports counterexamples.
