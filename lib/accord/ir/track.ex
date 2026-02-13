defmodule Accord.IR.Track do
  @moduledoc """
  A tracked accumulator in a protocol.

  Tracks are named state variables that persist across transitions and
  can be read by guards and mutated by updates.
  """

  @type t :: %__MODULE__{
          name: atom(),
          type: Accord.IR.Type.t(),
          default: term(),
          span: Pentiment.Span.t() | nil
        }

  @enforce_keys [:name, :type, :default]
  defstruct [:name, :type, :default, :span]
end
