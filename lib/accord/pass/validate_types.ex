defmodule Accord.Pass.ValidateTypes do
  @moduledoc """
  Validates type-level well-formedness of the IR.

  Checks:
  - Track defaults conform to their declared types.
  - Every non-cast transition has at least one branch.
  """

  alias Accord.IR
  alias Accord.Type.Check
  alias Pentiment.{Label, Report}

  @spec run(IR.t()) :: {:ok, IR.t()} | {:error, [Report.t()]}
  def run(%IR{} = ir) do
    errors =
      []
      |> check_track_defaults(ir)
      |> check_branches_present(ir)

    case errors do
      [] -> {:ok, ir}
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  defp check_track_defaults(errors, %IR{tracks: tracks} = ir) do
    Enum.reduce(tracks, errors, fn track, acc ->
      case Check.check(track.default, track.type) do
        :ok ->
          acc

        {:error, _reason} ->
          report =
            Report.error(
              "track :#{track.name} default #{inspect(track.default)} does not conform to type #{IR.Type.to_string(track.type)}"
            )
            |> Report.with_code("E010")
            |> maybe_add_source(ir.source_file)
            |> maybe_add_span_label(track.span, "declared here")

          [report | acc]
      end
    end)
  end

  defp check_branches_present(errors, %IR{states: states} = ir) do
    all_transitions =
      Enum.flat_map(states, fn {_name, state} -> state.transitions end) ++ ir.anystate

    Enum.reduce(all_transitions, errors, fn transition, acc ->
      if transition.kind == :call and transition.branches == [] do
        report =
          Report.error("call transition has no branches (no reply type declared)")
          |> Report.with_code("E011")
          |> maybe_add_source(ir.source_file)
          |> maybe_add_span_label(transition.span, "this transition needs a reply type")

        [report | acc]
      else
        acc
      end
    end)
  end

  defp maybe_add_source(report, nil), do: report
  defp maybe_add_source(report, source), do: Report.with_source(report, source)

  defp maybe_add_span_label(report, nil, _msg), do: report

  defp maybe_add_span_label(report, span, msg) do
    Report.with_label(report, Label.primary(span, msg))
  end
end
