defmodule Accord.IR.Check do
  @moduledoc """
  An individual check within a property block.

  Each check has a `kind` that determines what is being verified and a
  `spec` containing kind-specific data.

  ## Kinds

  - `:invariant` — global invariant: `fn tracks -> bool`.
  - `:local_invariant` — state/message-conditioned: `fn msg, tracks -> bool`.
  - `:action` — pre/post comparison: `fn old_tracks, new_tracks -> bool`.
  - `:liveness` — temporal property: trigger state leads to target state.
  - `:correspondence` — open event must be followed by close event.
  - `:bounded` — track value stays within a bound.
  - `:ordered` — events arrive in order by a field.
  - `:precedence` — target state requires prior state.
  - `:reachable` — target state is reachable (design-time only).
  - `:forbidden` — negated invariant: `fn state, tracks -> bool`.
  """

  @type kind ::
          :invariant
          | :local_invariant
          | :action
          | :liveness
          | :correspondence
          | :bounded
          | :ordered
          | :precedence
          | :reachable
          | :forbidden

  @type t :: %__MODULE__{
          kind: kind(),
          spec: term(),
          span: Pentiment.Span.t() | nil
        }

  @enforce_keys [:kind, :spec]
  defstruct [:kind, :spec, :span]
end
