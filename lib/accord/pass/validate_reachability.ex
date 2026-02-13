defmodule Accord.Pass.ValidateReachability do
  @moduledoc """
  Validates state graph reachability.

  Checks:
  - All non-terminal states are reachable from the initial state.
  - At least one terminal state is reachable from the initial state.

  All issues are warnings (logged, not fatal). Returns `{:ok, ir}` always.
  """

  require Logger

  alias Accord.IR
  alias Pentiment.{Label, Report}

  @spec run(IR.t()) :: {:ok, IR.t()}
  def run(%IR{} = ir) do
    {:ok, ir}
  end

  @doc """
  Returns reachability warnings without logging.

  Useful for testing.
  """
  @spec warnings(IR.t()) :: [Report.t()]
  def warnings(%IR{} = ir) do
    reachable = compute_reachable(ir)
    all_states = Map.keys(ir.states)

    []
    |> check_unreachable_states(ir, reachable, all_states)
    |> check_terminal_reachable(ir, reachable)
    |> Enum.reverse()
  end

  # BFS from initial state, following all transition targets.
  defp compute_reachable(%IR{initial: initial, states: states, anystate: anystate}) do
    bfs([initial], MapSet.new(), states, anystate)
  end

  defp bfs([], visited, _states, _anystate), do: visited

  defp bfs([current | rest], visited, states, anystate) do
    if MapSet.member?(visited, current) do
      bfs(rest, visited, states, anystate)
    else
      visited = MapSet.put(visited, current)

      state = Map.get(states, current, %IR.State{name: current})

      # Collect next states from this state's transitions and anystate.
      next_states =
        (state.transitions ++ anystate)
        |> Enum.flat_map(fn transition ->
          Enum.map(transition.branches, fn branch ->
            case branch.next_state do
              :__same__ -> current
              target -> target
            end
          end)
        end)
        |> Enum.reject(&MapSet.member?(visited, &1))

      bfs(next_states ++ rest, visited, states, anystate)
    end
  end

  defp check_unreachable_states(warnings, ir, reachable, all_states) do
    unreachable =
      all_states
      |> Enum.reject(&MapSet.member?(reachable, &1))
      |> Enum.reject(fn name -> ir.states[name].terminal end)

    Enum.reduce(unreachable, warnings, fn name, acc ->
      state = ir.states[name]

      report =
        Report.warning("state :#{name} is unreachable from initial state :#{ir.initial}")
        |> Report.with_code("W001")
        |> maybe_add_source(ir.source_file)
        |> maybe_add_span_label(state.span, "unreachable state")

      [report | acc]
    end)
  end

  defp check_terminal_reachable(warnings, ir, reachable) do
    has_terminal =
      Enum.any?(ir.states, fn {name, state} ->
        state.terminal and MapSet.member?(reachable, name)
      end)

    # Only check if there are terminal states defined at all.
    has_any_terminal = Enum.any?(ir.states, fn {_name, state} -> state.terminal end)

    if has_any_terminal and not has_terminal do
      report =
        Report.warning("no terminal state is reachable from initial state :#{ir.initial}")
        |> Report.with_code("W002")
        |> maybe_add_source(ir.source_file)
        |> Report.with_help("consider adding a transition to a terminal state")

      [report | warnings]
    else
      warnings
    end
  end

  defp maybe_add_source(report, nil), do: report
  defp maybe_add_source(report, source), do: Report.with_source(report, source)

  defp maybe_add_span_label(report, nil, _msg), do: report

  defp maybe_add_span_label(report, span, msg) do
    Report.with_label(report, Label.primary(span, msg))
  end
end
