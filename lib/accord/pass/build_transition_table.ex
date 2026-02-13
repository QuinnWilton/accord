defmodule Accord.Pass.BuildTransitionTable do
  @moduledoc """
  Flattens validated IR into a runtime transition table.

  Merges anystate transitions into each non-terminal state, producing
  a `{state, message_tag}` → `Transition` lookup map.
  """

  alias Accord.IR
  alias Accord.Monitor.TransitionTable

  @spec run(IR.t()) :: {:ok, TransitionTable.t()}
  def run(%IR{} = ir) do
    terminal_states =
      ir.states
      |> Enum.filter(fn {_name, state} -> state.terminal end)
      |> Enum.map(fn {name, _state} -> name end)
      |> MapSet.new()

    table =
      ir.states
      |> Enum.reject(fn {_name, state} -> state.terminal end)
      |> Enum.flat_map(fn {state_name, state} ->
        all_transitions = state.transitions ++ ir.anystate

        Enum.map(all_transitions, fn transition ->
          tag = message_tag(transition.message_pattern)
          {{state_name, tag}, transition}
        end)
      end)
      |> Map.new()

    {:ok, %TransitionTable{table: table, terminal_states: terminal_states}}
  end

  defp message_tag(pattern) when is_atom(pattern), do: pattern
  defp message_tag(pattern) when is_tuple(pattern), do: elem(pattern, 0)
end
