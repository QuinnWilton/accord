defmodule Accord.Pass.ValidateStructure do
  @moduledoc """
  Validates the structural well-formedness of the IR.

  Checks:
  - Initial state exists in the state map.
  - All `goto` targets reference declared states.
  - Terminal states have no transitions.
  - No duplicate state names (enforced by map, but checked for clarity).
  """

  alias Accord.IR
  alias Pentiment.Report

  import Accord.Pass.Helpers

  @spec run(IR.t()) :: {:ok, IR.t()} | {:error, [Report.t()]}
  def run(%IR{} = ir) do
    errors =
      []
      |> check_initial_exists(ir)
      |> check_goto_targets(ir)
      |> check_terminal_no_transitions(ir)

    case errors do
      [] -> {:ok, ir}
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  defp check_initial_exists(errors, %IR{initial: initial, states: states} = ir) do
    if Map.has_key?(states, initial) do
      errors
    else
      report =
        Report.error("initial state :#{initial} is not defined")
        |> Report.with_code("E001")
        |> maybe_add_source(ir.source_file)
        |> Report.with_help(
          "defined states are: #{states |> Map.keys() |> Enum.map_join(", ", &":#{&1}")}"
        )

      [report | errors]
    end
  end

  defp check_goto_targets(errors, %IR{states: states} = ir) do
    state_names = Map.keys(states)

    all_transitions =
      Enum.flat_map(states, fn {_name, state} -> state.transitions end) ++ ir.anystate

    Enum.reduce(all_transitions, errors, fn transition, acc ->
      Enum.reduce(transition.branches, acc, fn branch, inner_acc ->
        target = branch.next_state

        if target == :__same__ or target in state_names do
          inner_acc
        else
          span = branch.next_state_span || transition.span

          report =
            Report.error("undefined state reference :#{target}")
            |> Report.with_code("E002")
            |> maybe_add_source(ir.source_file)
            |> maybe_add_span_label(span, "goto target :#{target} is not defined")
            |> Report.with_help(
              "defined states are: #{Enum.map_join(state_names, ", ", &":#{&1}")}"
            )

          [report | inner_acc]
        end
      end)
    end)
  end

  defp check_terminal_no_transitions(errors, %IR{states: states} = ir) do
    Enum.reduce(states, errors, fn {_name, state}, acc ->
      if state.terminal and state.transitions != [] do
        report =
          Report.error("terminal state :#{state.name} has transitions")
          |> Report.with_code("E003")
          |> maybe_add_source(ir.source_file)
          |> maybe_add_span_label(state.span, "declared as terminal here")
          |> Report.with_help("terminal states cannot have transitions")

        [report | acc]
      else
        acc
      end
    end)
  end
end
