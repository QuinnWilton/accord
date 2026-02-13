defmodule Accord.IR.State do
  @moduledoc """
  A named state in a protocol state machine.
  """

  @type t :: %__MODULE__{
          name: atom(),
          terminal: boolean(),
          transitions: [Accord.IR.Transition.t()],
          span: Pentiment.Span.t() | nil
        }

  @enforce_keys [:name]
  defstruct [:name, :span, terminal: false, transitions: []]
end
