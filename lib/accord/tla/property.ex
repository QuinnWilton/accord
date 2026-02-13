defmodule Accord.TLA.Property do
  @moduledoc """
  TLA+ property representation.

  Produced by the `BuildProperties` pass. Each property maps to a TLA+
  formula — either an INVARIANT (state predicate), a temporal PROPERTY,
  or an auxiliary definition.
  """

  @type kind :: :invariant | :temporal | :auxiliary

  @type t :: %__MODULE__{
          name: String.t(),
          kind: kind(),
          formula: String.t(),
          comment: String.t() | nil
        }

  @enforce_keys [:name, :kind, :formula]
  defstruct [
    :name,
    :kind,
    :formula,
    :comment
  ]
end
