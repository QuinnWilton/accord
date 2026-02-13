defmodule Accord.Monitor.TransitionTable do
  @moduledoc """
  Flattened lookup structure for runtime message dispatch.

  Maps `{state, message_tag}` pairs to transitions. Anystate transitions
  are merged into each non-terminal state at build time.
  """

  alias Accord.IR.Transition

  @type message_tag :: atom()
  @type key :: {state :: atom(), message_tag()}

  @type t :: %__MODULE__{
          table: %{key() => Transition.t()},
          terminal_states: MapSet.t(atom())
        }

  @enforce_keys [:table, :terminal_states]
  defstruct [:table, :terminal_states]

  @doc """
  Looks up a transition for the given state and message.

  Returns `{:ok, transition}` or `:error`.
  """
  @spec lookup(t(), atom(), term()) :: {:ok, Transition.t()} | :error
  def lookup(%__MODULE__{table: table}, state, message) do
    tag = message_tag(message)

    case Map.fetch(table, {state, tag}) do
      {:ok, _} = ok -> ok
      :error -> :error
    end
  end

  @doc """
  Returns whether the given state is terminal.
  """
  @spec terminal?(t(), atom()) :: boolean()
  def terminal?(%__MODULE__{terminal_states: terminals}, state) do
    MapSet.member?(terminals, state)
  end

  @doc """
  Extracts the message tag used for dispatch.

  Atom messages use the atom itself. Tuple messages use the first element.
  """
  @spec message_tag(term()) :: atom()
  def message_tag(message) when is_atom(message), do: message
  def message_tag(message) when is_tuple(message), do: elem(message, 0)
end
