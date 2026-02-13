defmodule Accord.Pass.TLA.BuildStateSpace do
  @moduledoc """
  TLA+ pass: IR → StateSpace.

  Produces VARIABLES, TypeInvariant, and Init predicate from states,
  tracks, and roles. For two-party protocols: a single `state` variable
  plus one variable per track. Adds an `event` variable when local
  invariants exist (needed for conditioning on message type in TLA+).
  """

  alias Accord.IR
  alias Accord.TLA.{ModelConfig, StateSpace}

  @spec run(IR.t(), ModelConfig.t()) :: {:ok, StateSpace.t()}
  def run(%IR{} = ir, %ModelConfig{} = config) do
    states = Map.keys(ir.states) |> Enum.map(&state_to_tla/1)
    has_local_inv = has_local_invariants?(ir)

    # Build variable list.
    state_var = %{
      name: "state",
      type: state_type_expr(states),
      init: ~s("#{ir.initial}")
    }

    track_vars =
      Enum.map(ir.tracks, fn track ->
        domain = ModelConfig.resolve_domain(config, track.name, track.type)

        %{
          name: Atom.to_string(track.name),
          type: ModelConfig.domain_to_tla(domain),
          init: value_to_tla(track.default)
        }
      end)

    event_var =
      if has_local_inv do
        [%{name: "event", type: ~s(STRING), init: ~s("none")}]
      else
        []
      end

    variables = [state_var] ++ track_vars ++ event_var

    # Build TypeInvariant.
    type_invariant = build_type_invariant(variables)

    # Build Init.
    init = build_init(variables)

    # Build module name.
    module_name =
      ir.name
      |> Module.split()
      |> List.last()

    state_space = %StateSpace{
      module_name: module_name,
      variables: variables,
      type_invariant: type_invariant,
      init: init,
      states: states,
      has_event_var: has_local_inv
    }

    {:ok, state_space}
  end

  defp state_to_tla(state_name), do: Atom.to_string(state_name)

  defp state_type_expr(states) do
    elements = Enum.map_join(states, ", ", &~s("#{&1}"))
    "{#{elements}}"
  end

  defp value_to_tla(nil), do: "NULL"
  defp value_to_tla(true), do: "TRUE"
  defp value_to_tla(false), do: "FALSE"
  defp value_to_tla(n) when is_integer(n), do: Integer.to_string(n)
  defp value_to_tla(s) when is_binary(s), do: ~s("#{s}")
  defp value_to_tla(a) when is_atom(a), do: ~s("#{a}")
  defp value_to_tla(_), do: "NULL"

  defp build_type_invariant(variables) do
    conjuncts =
      Enum.map_join(variables, "\n    /\\ ", fn var ->
        "#{var.name} \\in #{var.type}"
      end)

    "TypeInvariant == \n    /\\ #{conjuncts}"
  end

  defp build_init(variables) do
    conjuncts =
      Enum.map_join(variables, "\n    /\\ ", fn var ->
        "#{var.name} = #{var.init}"
      end)

    "Init == \n    /\\ #{conjuncts}"
  end

  defp has_local_invariants?(%IR{properties: properties}) do
    Enum.any?(properties, fn prop ->
      Enum.any?(prop.checks, fn check -> check.kind == :local_invariant end)
    end)
  end
end
