# ADR-003: ternary blame model

## Status

Accepted

## Context

When a protocol violation occurs, the monitor needs to report who is responsible. The simplest model is binary blame: either the caller or the callee broke the contract. This works for message and reply violations but falls apart for property violations.

Consider a liveness property: "if the lock is acquired, it must eventually be released." If this property times out, neither the last client message nor the last server reply is individually at fault. The violation emerges from the system's behavior over time, not from a single interaction. Forcing it into a binary caller/callee model would produce misleading diagnostics.

Similarly, an action property like "fence tokens must be monotonically increasing" can fail because of a sequence of individually valid interactions that together violate a global invariant. Blaming either party for a single step misattributes the problem.

## Decision

Blame is one of three values:

- **`:client`** -- the client sent a message that violates the protocol. This covers `:invalid_message` (wrong message for current state), `:argument_type` (message argument has wrong type), `:guard_failed` (guard precondition returned false), and `:session_ended` (message sent after terminal state).
- **`:server`** -- the server returned a reply that violates the protocol. This covers `:invalid_reply` (reply doesn't match any branch type) and `:timeout` (server didn't respond within the configured window).
- **`:property`** -- a temporal or aggregate property was violated, which is not attributable to either party in isolation. This covers `:invariant_violated`, `:action_violated`, `:liveness_violated`, `:precedence_violated`, and `:ordering_violated`.

The `Accord.Violation` struct carries `blame` alongside `kind`, `state`, `message`, and optional `context` for structured metadata specific to each violation kind.

## Consequences

**Positive:**

- Violation handlers can route on blame to take different actions. For example, a `:client` violation might return an error tuple, a `:server` violation might trigger an alert, and a `:property` violation might log for later analysis.
- Error messages are honest about attribution. Property violations say "this property failed" rather than incorrectly pointing at the last message sender.
- The model extends naturally to new property kinds without needing to artificially assign them to client or server.

**Negative:**

- Consumers must handle three cases instead of two. Code that switches on blame needs a `:property` branch even if it only cares about client/server.
- Some property violations have a temporal component (liveness) while others are immediate (invariant on a single transition). Grouping them under the same blame category loses that distinction, though the `kind` field preserves it.
