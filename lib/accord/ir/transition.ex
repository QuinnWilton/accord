defmodule Accord.IR.Transition do
  @moduledoc """
  A transition within a protocol state.

  Represents a message that can be sent in a given state, with type
  constraints on arguments, optional guard and update functions, and
  one or more branches mapping reply types to next states.
  """

  @type guard_pair :: %{fun: function(), ast: Macro.t()}

  @type t :: %__MODULE__{
          from: atom() | nil,
          to: atom() | nil,
          message_pattern: term(),
          message_types: [Accord.IR.Type.t()],
          message_arg_names: [String.t() | nil],
          message_arg_spans: [Pentiment.Span.t() | nil],
          kind: :call | :cast,
          branches: [Accord.IR.Branch.t()],
          guard: guard_pair() | nil,
          update: guard_pair() | nil,
          span: Pentiment.Span.t() | nil
        }

  @enforce_keys [:message_pattern, :kind]
  defstruct [
    :from,
    :to,
    :message_pattern,
    :kind,
    :guard,
    :update,
    :span,
    message_types: [],
    message_arg_names: [],
    message_arg_spans: [],
    branches: []
  ]
end
