defmodule Accord.TLA.Action do
  @moduledoc """
  TLA+ action representation.

  Produced by the `BuildActions` pass. Each action corresponds to a
  protocol transition and contains preconditions, primed variable
  assignments, and the UNCHANGED set.
  """

  @type t :: %__MODULE__{
          name: String.t(),
          source_state: String.t(),
          target_state: String.t(),
          message_tag: String.t(),
          preconditions: [String.t()],
          existential_vars: [{String.t(), String.t()}],
          primed: %{String.t() => String.t()},
          unchanged: [String.t()],
          comment: String.t() | nil
        }

  @enforce_keys [:name, :source_state, :target_state, :message_tag]
  defstruct [
    :name,
    :source_state,
    :target_state,
    :message_tag,
    :comment,
    preconditions: [],
    existential_vars: [],
    primed: %{},
    unchanged: []
  ]
end
