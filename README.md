# Accord

Runtime protocol contracts for Elixir with blame assignment and TLA+ model checking.

Accord lets you define a state machine protocol — states, transitions, typed messages, guards, tracked state, and temporal properties — using a compile-time DSL. It generates:

- A **runtime monitor** (gen_statem proxy) that validates every message at runtime and assigns blame (client, server, or property) on violations.
- A **TLA+ specification** for exhaustive model checking with TLC.

## Quick example

```elixir
defmodule Counter.Protocol do
  use Accord.Protocol

  initial :ready

  state :ready do
    on {:increment, amount :: pos_integer()}, reply: {:ok, integer()}, goto: :ready
    on :get, reply: {:value, integer()}, goto: :ready
    on :stop, reply: :stopped, goto: :stopped
  end

  state :stopped, terminal: true

  anystate do
    on :ping, reply: :pong
    cast :heartbeat
  end
end
```

This defines a protocol where `:ready` accepts `{:increment, amount}`, `:get`, and `:stop` messages, and any non-terminal state accepts `:ping` and `:heartbeat`. Message arguments are type-checked at runtime, and the monitor rejects messages not valid in the current state.

## Core concepts

- **States** define the protocol's state machine. Each state has transitions. Terminal states accept no messages.
- **Transitions** define which messages a state accepts, their typed arguments, expected reply types, and the next state.
- **Tracks** are named accumulators updated on transitions. They carry protocol-level state (e.g., a fence token, a counter).
- **Guards** are predicates evaluated before forwarding a message to the server.
- **Properties** express invariants, action properties, liveness, correspondence, bounds, ordering, precedence, reachability, and forbidden states — checked at runtime by the monitor and at design time by TLA+.
- **Roles** declare participant identities for multi-party protocols.
- **Blame** is assigned on violations: `:client` (sent an invalid message), `:server` (returned a wrong reply), or `:property` (a declared property was violated).

## Properties

```elixir
property :monotonic_tokens do
  action fn old, new -> new.fence_token >= old.fence_token end
end

property :holder_set do
  invariant :locked, fn _msg, tracks -> tracks.holder != nil end
end

property :no_starvation do
  liveness in_state(:locked), leads_to: in_state(:unlocked)
end

property :acquire_release do
  correspondence :acquire, [:release]
end

property :token_bounded do
  bounded :fence_token, max: 1000
end
```

## TLA+ integration

At compile time, Accord generates a TLA+ specification and TLC configuration from the protocol definition. Message types become finite domains, guards become enabling conditions, and properties become TLA+ invariants or temporal formulas.

```bash
mix accord.tla Counter.Protocol          # print the generated .tla spec
mix accord.tla Counter.Protocol --cfg    # print the .cfg file
mix accord.check                         # model-check all protocols
mix accord.check Counter.Protocol        # model-check a specific protocol
mix accord.check --workers 4             # TLC parallelism
```

TLC requires Java and `tla2tools.jar`. Set the `TLA2TOOLS_JAR` environment variable, place it at `~/.tla/tla2tools.jar`, or in the project root.

## Installation

Add `accord` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:accord, "~> 0.1.0"}
  ]
end
```

## License

MIT - see [LICENSE](LICENSE) for details.
