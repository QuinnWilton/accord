defmodule Accord.IR.Property do
  @moduledoc """
  A named container for one or more protocol checks.

  Properties group related checks under a descriptive name. Each check
  within the property is an `Accord.IR.Check` with its own kind and spec.
  """

  @type t :: %__MODULE__{
          name: atom(),
          checks: [Accord.IR.Check.t()],
          span: Pentiment.Span.t() | nil
        }

  @enforce_keys [:name]
  defstruct [:name, :span, checks: []]
end
