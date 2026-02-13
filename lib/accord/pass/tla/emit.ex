defmodule Accord.Pass.TLA.Emit do
  @moduledoc """
  TLA+ pass: StateSpace + Actions + Properties → String.

  Pure string generation. Renders a complete `.tla` module and `.cfg`
  file from the compiled TLA+ intermediate representation.
  """

  alias Accord.TLA.{Action, Property, StateSpace}

  @spec run(StateSpace.t(), [Action.t()], [Property.t()]) :: {:ok, %{tla: String.t(), cfg: String.t()}}
  def run(%StateSpace{} = ss, actions, properties) do
    tla = render_tla(ss, actions, properties)
    cfg = render_cfg(ss, actions, properties)
    {:ok, %{tla: tla, cfg: cfg}}
  end

  # -- TLA+ Module --

  defp render_tla(ss, actions, properties) do
    var_names = Enum.map(ss.variables, & &1.name)
    vars_decl = Enum.join(var_names, ", ")

    sections = [
      "---- MODULE #{ss.module_name} ----",
      "EXTENDS Integers, Sequences, TLC",
      "",
      "VARIABLES #{vars_decl}",
      "",
      "vars == <<#{vars_decl}>>",
      "",
      render_tla_section("Type invariant", ss.type_invariant),
      render_tla_section("Init predicate", ss.init),
      render_tla_actions(actions),
      render_tla_next(actions),
      render_tla_spec(actions),
      render_tla_properties(properties),
      "===="
    ]

    Enum.join(sections, "\n") <> "\n"
  end

  defp render_tla_section(comment, body) do
    """
    \\* #{comment}
    #{body}
    """
  end

  defp render_tla_actions(actions) do
    actions
    |> Enum.map(&render_tla_action/1)
    |> Enum.join("\n")
  end

  defp render_tla_action(%Action{} = action) do
    lines = []

    # Comment.
    lines = if action.comment, do: lines ++ ["\\* #{action.comment}"], else: lines

    # Build the action body.
    body_parts = []

    # Preconditions.
    body_parts = body_parts ++ Enum.map(action.preconditions, &"/\\ #{&1}")

    # Primed assignments.
    body_parts =
      body_parts ++
        (action.primed
         |> Enum.sort_by(fn {k, _} -> k end)
         |> Enum.map(fn {var, expr} -> "/\\ #{var}' = #{expr}" end))

    # UNCHANGED.
    body_parts =
      case action.unchanged do
        [] -> body_parts
        [single] -> body_parts ++ ["/\\ UNCHANGED #{single}"]
        multiple -> body_parts ++ ["/\\ UNCHANGED <<#{Enum.join(multiple, ", ")}>>"]
      end

    # Wrap in existential quantification if needed.
    body = Enum.map_join(body_parts, "\n    ", & &1)

    action_def =
      case action.existential_vars do
        [] ->
          "#{action.name} ==\n    #{body}"

        evars ->
          quantifiers =
            Enum.map_join(evars, ", ", fn {var, domain} ->
              "#{var} \\in #{domain}"
            end)

          "#{action.name} ==\n  \\E #{quantifiers} :\n    #{body}"
      end

    lines = lines ++ [action_def]
    Enum.join(lines, "\n") <> "\n"
  end

  defp render_tla_next(actions) do
    if actions == [] do
      "Next == FALSE\n"
    else
      disjuncts = Enum.map_join(actions, "\n    \\/ ", & &1.name)

      """
      \\* Next state relation
      Next ==
          \\/ #{disjuncts}
      """
    end
  end

  defp render_tla_spec(_actions) do
    """
    \\* Specification
    Spec == Init /\\ [][Next]_vars
    """
  end

  defp render_tla_properties(properties) do
    if properties == [] do
      ""
    else
      props =
        properties
        |> Enum.map(fn prop ->
          comment = if prop.comment, do: "\\* #{prop.comment}\n", else: ""
          "#{comment}#{prop.formula}\n"
        end)
        |> Enum.join("\n")

      "\\* Properties\n#{props}"
    end
  end

  # -- CFG File --

  defp render_cfg(ss, _actions, properties) do
    sections = [
      "SPECIFICATION Spec",
      "",
      "INVARIANT TypeInvariant"
    ]

    # Add invariant properties.
    invariants =
      properties
      |> Enum.filter(&(&1.kind == :invariant))
      |> Enum.map(&"INVARIANT #{&1.name}")

    # Add temporal properties.
    temporals =
      properties
      |> Enum.filter(&(&1.kind == :temporal))
      |> Enum.map(&"PROPERTY #{&1.name}")

    # Add constants for NULL if any track has nil default.
    constants =
      if Enum.any?(ss.variables, &(&1.init == "NULL")) do
        ["", "CONSTANT NULL = NULL"]
      else
        []
      end

    all_sections = sections ++ invariants ++ temporals ++ constants
    Enum.join(all_sections, "\n") <> "\n"
  end
end
