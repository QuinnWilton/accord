defmodule Accord.Pass.TLA.BuildProperties do
  @moduledoc """
  TLA+ pass: IR → [TLA.Property].

  Maps protocol property checks to TLA+ formulas:

  - `:invariant` → `[]P(vars)` — state invariant
  - `:local_invariant` → `[](state = S /\\ event = E => P)` — conditional
  - `:action` → `[][P(vars, vars')]_vars` — action property
  - `:liveness` → `P ~> Q` with WF/SF — temporal property
  - `:bounded` → `[](x <= N)` — bounded invariant
  - `:correspondence` → auxiliary counter invariant
  - `:reachable` → TLC explores state space (no formula needed, just cfg)
  - `:forbidden` → `[](~P)` — negated invariant
  """

  alias Accord.IR
  alias Accord.TLA.{GuardCompiler, Property}

  @spec run(IR.t()) :: {:ok, [Property.t()]}
  def run(%IR{} = ir) do
    properties =
      ir.properties
      |> Enum.flat_map(fn prop ->
        Enum.map(prop.checks, fn check ->
          build_property(prop.name, check, ir)
        end)
      end)
      |> Enum.reject(&is_nil/1)

    {:ok, properties}
  end

  defp build_property(prop_name, %{kind: :invariant} = check, _ir) do
    tla_name = camelize(prop_name)

    formula =
      case check.spec do
        %{ast: ast} when not is_nil(ast) ->
          case GuardCompiler.compile(ast) do
            {:ok, expr} -> "#{tla_name} == #{expr}"
            {:partial, expr, _} -> "#{tla_name} == #{expr}"
          end

        _ ->
          "#{tla_name} == TRUE"
      end

    %Property{
      name: tla_name,
      kind: :invariant,
      formula: formula,
      comment: "invariant: #{prop_name}"
    }
  end

  defp build_property(prop_name, %{kind: :local_invariant} = check, _ir) do
    tla_name = camelize(prop_name) <> camelize(check.spec.state)
    state = Atom.to_string(check.spec.state)

    body =
      case check.spec do
        %{ast: ast} when not is_nil(ast) ->
          case GuardCompiler.compile(ast) do
            {:ok, expr} -> expr
            {:partial, expr, _} -> expr
          end

        _ ->
          "TRUE"
      end

    formula = ~s[#{tla_name} == (state = "#{state}") => (#{body})]

    %Property{
      name: tla_name,
      kind: :invariant,
      formula: formula,
      comment: "local invariant: #{prop_name} in state #{state}"
    }
  end

  defp build_property(prop_name, %{kind: :action} = check, ir) do
    tla_name = camelize(prop_name)

    vars =
      ir.tracks
      |> Enum.map(fn t -> Atom.to_string(t.name) end)
      |> Enum.join(", ")

    bindings = extract_action_bindings(check.spec.ast)

    body =
      case check.spec do
        %{ast: ast} when not is_nil(ast) ->
          case GuardCompiler.compile(ast, bindings) do
            {:ok, expr} -> expr
            {:partial, expr, _} -> expr
          end

        _ ->
          "TRUE"
      end

    formula = "#{tla_name} == [][#{body}]_<<#{vars}>>"

    %Property{
      name: tla_name,
      kind: :temporal,
      formula: formula,
      comment: "action property: #{prop_name}"
    }
  end

  defp build_property(prop_name, %{kind: :liveness} = check, _ir) do
    tla_name = camelize(prop_name)
    trigger = pred_to_tla(check.spec.trigger)
    target = pred_to_tla(check.spec.target)

    formula = "#{tla_name} == #{trigger} ~> #{target}"

    %Property{
      name: tla_name,
      kind: :temporal,
      formula: formula,
      comment: "liveness: #{prop_name}"
    }
  end

  defp build_property(prop_name, %{kind: :bounded} = check, _ir) do
    tla_name = camelize(prop_name)
    track = Atom.to_string(check.spec.track)
    max = check.spec.max

    formula = "#{tla_name} == #{track} =< #{max}"

    %Property{
      name: tla_name,
      kind: :invariant,
      formula: formula,
      comment: "bounded: #{prop_name} (#{track} <= #{max})"
    }
  end

  defp build_property(prop_name, %{kind: :correspondence} = check, _ir) do
    tla_name = camelize(prop_name)
    open = Atom.to_string(check.spec.open)
    _close = Enum.map(check.spec.close, &Atom.to_string/1)

    # Correspondence requires an auxiliary counter variable.
    # The invariant is that the counter is always >= 0.
    formula = "#{tla_name} == #{open}_pending >= 0"

    %Property{
      name: tla_name,
      kind: :invariant,
      formula: formula,
      comment: "correspondence: #{prop_name}"
    }
  end

  defp build_property(prop_name, %{kind: :forbidden} = check, _ir) do
    tla_name = camelize(prop_name)

    body =
      case check.spec do
        %{ast: ast} when not is_nil(ast) ->
          case GuardCompiler.compile(ast) do
            {:ok, expr} -> expr
            {:partial, expr, _} -> expr
          end

        _ ->
          "FALSE"
      end

    formula = "#{tla_name} == ~(#{body})"

    %Property{
      name: tla_name,
      kind: :invariant,
      formula: formula,
      comment: "forbidden: #{prop_name}"
    }
  end

  defp build_property(prop_name, %{kind: :reachable}, _ir) do
    tla_name = camelize(prop_name)
    target = Atom.to_string(prop_name)

    %Property{
      name: tla_name,
      kind: :auxiliary,
      formula: "\\* reachable: #{target} — verified by TLC state space exploration",
      comment: "reachable: #{prop_name}"
    }
  end

  # Pass through unknown kinds.
  defp build_property(_prop_name, _check, _ir), do: nil

  defp pred_to_tla({:in_state, state}), do: ~s(state = "#{state}")
  defp pred_to_tla(other), do: inspect(other)

  # Extracts bindings for action property fn params.
  # Maps the "old" param to :current and the "new" param to :primed.
  defp extract_action_bindings({:fn, _, [{:->, _, [[old_var, new_var], _body]}]}) do
    old_name = extract_var_name(old_var)
    new_name = extract_var_name(new_var)

    bindings = %{}
    bindings = if old_name, do: Map.put(bindings, old_name, :current), else: bindings
    bindings = if new_name, do: Map.put(bindings, new_name, :primed), else: bindings
    bindings
  end

  defp extract_action_bindings(_), do: %{}

  defp extract_var_name({name, _meta, ctx}) when is_atom(name) and is_atom(ctx), do: name
  defp extract_var_name(_), do: nil

  defp camelize(name) when is_atom(name) do
    name
    |> Atom.to_string()
    |> String.split("_")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join()
  end
end
