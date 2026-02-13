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
        type_str = ModelConfig.domain_to_tla(domain)

        # Include NULL in the type set when the track can be nil.
        type_str =
          if track.default == nil do
            "#{type_str} \\union {NULL}"
          else
            type_str
          end

        %{
          name: Atom.to_string(track.name),
          type: type_str,
          init: value_to_tla(track.default)
        }
      end)

    event_var =
      if has_local_inv do
        [%{name: "event", type: ~s(STRING), init: ~s("none")}]
      else
        []
      end

    # Build correspondence counter variables.
    correspondences = build_correspondences(ir)

    correspondence_vars =
      Enum.map(correspondences, fn corr ->
        %{name: corr.counter_var, type: "0..3", init: "0"}
      end)

    variables = [state_var] ++ track_vars ++ event_var ++ correspondence_vars

    # Build TypeInvariant.
    type_invariant = build_type_invariant(variables)

    # Build Init.
    init = build_init(variables)

    # Build module name.
    module_name =
      ir.name
      |> Module.split()
      |> List.last()

    # Collect model value constants needed for the cfg.
    constants = collect_constants(ir, config)

    state_space = %StateSpace{
      module_name: module_name,
      variables: variables,
      type_invariant: type_invariant,
      init: init,
      states: states,
      has_event_var: has_local_inv,
      correspondences: correspondences,
      constants: constants
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

  # Collects all model value constant names from resolved domains.
  # Includes NULL if any variable has a nil default.
  defp collect_constants(%IR{} = ir, %ModelConfig{} = config) do
    # Gather all domains: track domains + message type domains.
    track_domains =
      Enum.map(ir.tracks, fn track ->
        ModelConfig.resolve_domain(config, track.name, track.type)
      end)

    msg_type_domains =
      ir.states
      |> Enum.flat_map(fn {_name, state} ->
        state.transitions ++ if(state.terminal, do: [], else: ir.anystate)
      end)
      |> Enum.flat_map(fn transition ->
        Enum.map(transition.message_types, fn type ->
          ModelConfig.resolve_domain(config, :_, type)
        end)
      end)

    # Also include reply type domains for transitions with branches.
    reply_type_domains =
      ir.states
      |> Enum.flat_map(fn {_name, state} -> state.transitions end)
      |> Enum.flat_map(fn transition ->
        Enum.flat_map(transition.branches, fn branch ->
          extract_reply_types(branch.reply_type)
          |> Enum.map(fn type -> ModelConfig.resolve_domain(config, :_, type) end)
        end)
      end)

    all_domains = track_domains ++ msg_type_domains ++ reply_type_domains

    model_value_names =
      all_domains
      |> Enum.flat_map(&extract_model_value_names/1)
      |> Enum.uniq()
      |> Enum.sort()

    # Add NULL if any track defaults to nil.
    has_null = Enum.any?(ir.tracks, &(&1.default == nil))

    if has_null do
      Enum.uniq(["NULL" | model_value_names])
    else
      model_value_names
    end
  end

  defp extract_model_value_names({:model_values, count}) when is_integer(count) do
    Enum.map(1..count, &"mv#{&1}")
  end

  defp extract_model_value_names({:model_values, names}) when is_list(names) do
    Enum.map(names, &Atom.to_string/1)
  end

  defp extract_model_value_names(_), do: []

  defp extract_reply_types({:tagged, _tag, inner}), do: [inner]
  defp extract_reply_types(_), do: []

  defp build_correspondences(%IR{properties: properties}) do
    properties
    |> Enum.flat_map(fn prop ->
      prop.checks
      |> Enum.filter(&(&1.kind == :correspondence))
      |> Enum.map(fn check ->
        open = check.spec.open
        close = check.spec.close
        counter_var = "#{open}_pending"
        %{open: open, close: close, counter_var: counter_var}
      end)
    end)
  end
end
