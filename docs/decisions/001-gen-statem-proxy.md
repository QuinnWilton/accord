# ADR-001: gen_statem proxy for runtime monitoring

## Status

Accepted

## Context

Accord needs to intercept messages between client and server at runtime to validate them against the protocol specification. Several approaches exist for this kind of interposition:

- **Middleware/plug pipeline** -- requires the server to opt into a specific framework or callback structure. Couples the monitor to the server implementation.
- **Decorators/wrappers** -- modifies the server module at compile time by injecting validation logic around `handle_call`/`handle_cast`. Breaks if the server isn't a GenServer, and makes it hard to attribute blame because the validation runs inside the server process.
- **Compile-time code injection** -- rewrites the server's callback bodies to include protocol checks. Fragile across OTP versions and difficult to disable in production without recompilation.
- **Explicit proxy process** -- a separate process sits between client and server, forwarding messages after validation. Requires no changes to the server and can be removed without touching user code.

The key requirement is blame assignment: when a violation occurs, the monitor must determine whether the client sent a bad message or the server returned a bad reply. This requires observing both the outgoing message and the incoming reply as distinct steps, which is natural in a proxy but awkward inside the server process itself.

## Decision

The monitor is implemented as a gen_statem process that sits between client and server. It receives messages from the client, validates them against the protocol's transition table, forwards valid messages to the upstream server, validates the reply, and returns it to the client.

The proxy uses `handle_event_function` callback mode with a single state machine whose states mirror the protocol's declared states. Track values, correspondence counters, and liveness timers are maintained in the gen_statem data.

Clients interact with the monitor through `Accord.Monitor.call/3` and `Accord.Monitor.cast/2`, which wrap messages in tagged tuples (`{:accord_call, msg}` and `{:accord_cast, msg}`) so the monitor can distinguish protocol messages from internal gen_statem events.

## Consequences

**Positive:**

- Zero modification to user server code. The server is a plain GenServer that knows nothing about accord.
- Blame is straightforward: if the message fails validation before forwarding, the client is at fault. If the reply fails validation after the server responds, the server is at fault.
- The proxy can be conditionally started (e.g., only in dev/test) without recompiling the server.
- Property checking (invariants, action properties, liveness timers) fits naturally into the gen_statem lifecycle.
- The violation policy (`:log`, `:reject`, `:crash`, or custom callback) is configurable per monitor instance.

**Negative:**

- Adds one hop of latency per message (client -> monitor -> server -> monitor -> client).
- The monitor process is a single point of failure between client and server. If it crashes, the connection is severed.
- Clients must call through the monitor rather than directly to the server, which requires wiring changes at the call site.
