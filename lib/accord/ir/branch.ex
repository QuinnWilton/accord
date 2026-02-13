defmodule Accord.IR.Branch do
  @moduledoc """
  A reply-type to next-state mapping within a transition.

  Each branch declares the expected reply shape and the state to
  transition to when that reply is received.
  """

  @type t :: %__MODULE__{
          reply_type: Accord.IR.Type.t(),
          next_state: atom(),
          constraint: %{fun: function(), ast: Macro.t()} | nil,
          span: Pentiment.Span.t() | nil,
          next_state_span: Pentiment.Span.t() | nil
        }

  @enforce_keys [:reply_type, :next_state]
  defstruct [:reply_type, :next_state, :constraint, :span, :next_state_span]
end
