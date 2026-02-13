defmodule Accord.IR.Role do
  @moduledoc """
  A participant role in a protocol.
  """

  @type t :: %__MODULE__{
          name: atom(),
          span: Pentiment.Span.t() | nil
        }

  @enforce_keys [:name]
  defstruct [:name, :span]
end
