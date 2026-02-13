defmodule Accord.Pass.ValidateDeterminism do
  @moduledoc """
  Validates that no `(state, message_tag)` pair has ambiguous dispatch.

  For each state, checks that no two transitions share the same message
  tag. Anystate transitions are checked against every non-terminal state.
  """

  alias Accord.IR
  alias Pentiment.{Label, Report}

  @spec run(IR.t()) :: {:ok, IR.t()} | {:error, [Report.t()]}
  def run(%IR{} = ir) do
    errors =
      ir.states
      |> Enum.flat_map(fn {_name, state} ->
        unless state.terminal do
          check_state_determinism(state, ir.anystate, ir)
        else
          []
        end
      end)

    case errors do
      [] -> {:ok, ir}
      errors -> {:error, errors}
    end
  end

  defp check_state_determinism(state, anystate_transitions, ir) do
    all_transitions = state.transitions ++ anystate_transitions

    all_transitions
    |> Enum.group_by(&message_tag/1)
    |> Enum.flat_map(fn {tag, transitions} ->
      if length(transitions) > 1 do
        labels =
          transitions
          |> Enum.filter(& &1.span)
          |> Enum.with_index()
          |> Enum.map(fn {t, i} ->
            if i == 0 do
              Label.primary(t.span, "first definition")
            else
              Label.secondary(t.span, "conflicts with first")
            end
          end)

        report =
          Report.error(
            "ambiguous dispatch: state :#{state.name} has multiple transitions for message #{inspect(tag)}"
          )
          |> Report.with_code("E020")
          |> maybe_add_source(ir.source_file)
          |> Report.with_labels(labels)

        [report]
      else
        []
      end
    end)
  end

  defp maybe_add_source(report, nil), do: report
  defp maybe_add_source(report, source), do: Report.with_source(report, source)

  defp message_tag(%{message_pattern: pattern}) when is_atom(pattern), do: pattern

  defp message_tag(%{message_pattern: pattern}) when is_tuple(pattern) do
    elem(pattern, 0)
  end
end
