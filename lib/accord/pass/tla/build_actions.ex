defmodule Accord.Pass.TLA.BuildActions do
  @moduledoc """
  TLA+ pass: IR + StateSpace → [Action].

  Each protocol transition becomes a TLA+ action. Message types become
  `\\in` preconditions with existential quantification over domains.
  Guard ASTs become enabling conditions via the GuardCompiler. Update
  ASTs become primed variable assignments. UNCHANGED is derived from
  the complement of modified variables.
  """

  alias Accord.IR
  alias Accord.IR.Transition
  alias Accord.TLA.{Action, GuardCompiler, ModelConfig, StateSpace}

  @spec run(IR.t(), StateSpace.t(), ModelConfig.t()) :: {:ok, [Action.t()]}
  def run(%IR{} = ir, %StateSpace{} = state_space, %ModelConfig{} = config) do
    all_var_names =
      state_space.variables
      |> Enum.map(& &1.name)
      |> MapSet.new()

    actions =
      ir.states
      |> Enum.flat_map(fn {state_name, state} ->
        # Include anystate transitions for non-terminal states.
        transitions =
          if state.terminal do
            state.transitions
          else
            state.transitions ++ ir.anystate
          end

        Enum.flat_map(transitions, fn transition ->
          build_actions_for_transition(
            ir,
            state_name,
            transition,
            state_space,
            config,
            all_var_names
          )
        end)
      end)

    {:ok, actions}
  end

  defp build_actions_for_transition(
         ir,
         state_name,
         transition,
         state_space,
         config,
         all_var_names
       ) do
    tag = message_tag(transition.message_pattern)
    source = Atom.to_string(state_name)

    # For branching transitions, create one action per branch.
    case transition.branches do
      [] ->
        # Cast — no reply, no branch.
        [build_cast_action(ir, state_name, transition, tag, source, state_space, all_var_names)]

      branches ->
        Enum.map(branches, fn branch ->
          build_call_action(
            ir,
            state_name,
            transition,
            branch,
            tag,
            source,
            state_space,
            config,
            all_var_names
          )
        end)
    end
  end

  defp build_call_action(
         _ir,
         state_name,
         transition,
         branch,
         tag,
         source,
         state_space,
         config,
         all_var_names
       ) do
    target_state = resolve_next_state(branch.next_state, state_name)
    target = Atom.to_string(target_state)

    action_name = build_action_name(tag, source, target)

    # Build existential variables for message parameters.
    {existential_vars, param_bindings} =
      build_existentials(transition, config)

    # Preconditions.
    preconditions = [~s(state = "#{source}")]

    # Guard condition.
    guard_precondition =
      case transition.guard do
        %{ast: ast} when not is_nil(ast) ->
          case GuardCompiler.compile(ast, param_bindings) do
            {:ok, tla} -> [tla]
            {:partial, tla, _warnings} -> [tla]
          end

        _ ->
          []
      end

    # Primed assignments.
    primed = %{"state" => ~s("#{target}")}

    # Track updates from update AST.
    track_primed = build_track_primed(transition, state_space)

    # Event variable.
    event_primed =
      if state_space.has_event_var do
        %{"event" => ~s("#{tag}")}
      else
        %{}
      end

    all_primed = Map.merge(primed, Map.merge(track_primed, event_primed))

    # UNCHANGED: variables not in primed set.
    unchanged =
      all_var_names
      |> MapSet.difference(MapSet.new(Map.keys(all_primed)))
      |> MapSet.to_list()
      |> Enum.sort()

    %Action{
      name: action_name,
      source_state: source,
      target_state: target,
      message_tag: tag,
      preconditions: preconditions ++ guard_precondition,
      existential_vars: existential_vars,
      primed: all_primed,
      unchanged: unchanged,
      comment: "#{tag} from #{source} to #{target}"
    }
  end

  defp build_cast_action(_ir, _state_name, _transition, tag, source, state_space, all_var_names) do
    # Casts don't change state (stay in same state).
    target = source
    action_name = "Cast#{camelize(tag)}From#{camelize(source)}"

    primed = %{}

    event_primed =
      if state_space.has_event_var do
        %{"event" => ~s("#{tag}")}
      else
        %{}
      end

    all_primed = Map.merge(primed, event_primed)

    unchanged =
      all_var_names
      |> MapSet.difference(MapSet.new(Map.keys(all_primed)))
      |> MapSet.to_list()
      |> Enum.sort()

    %Action{
      name: action_name,
      source_state: source,
      target_state: target,
      message_tag: tag,
      preconditions: [~s(state = "#{source}")],
      existential_vars: [],
      primed: all_primed,
      unchanged: unchanged,
      comment: "cast #{tag} in #{source}"
    }
  end

  defp build_existentials(%Transition{message_pattern: pattern, message_types: types}, config) do
    case pattern do
      pat when is_tuple(pat) ->
        args = pat |> Tuple.to_list() |> tl()

        {vars, bindings} =
          args
          |> Enum.zip(types)
          |> Enum.with_index()
          |> Enum.reduce({[], %{}}, fn {{arg, type}, idx}, {vars_acc, bindings_acc} ->
            param_name = extract_param_name(arg, idx)
            tla_var = "msg_#{param_name}"
            domain = ModelConfig.resolve_domain(config, param_name, type)
            domain_tla = ModelConfig.domain_to_tla(domain)
            {[{tla_var, domain_tla} | vars_acc], Map.put(bindings_acc, param_name, tla_var)}
          end)

        {Enum.reverse(vars), bindings}

      _ ->
        {[], %{}}
    end
  end

  defp extract_param_name(:_, idx), do: :"arg#{idx}"
  defp extract_param_name(name, _idx) when is_atom(name), do: name
  defp extract_param_name(_, idx), do: :"arg#{idx}"

  defp build_track_primed(%Transition{update: nil}, _state_space), do: %{}

  defp build_track_primed(%Transition{update: %{ast: ast}}, state_space) when not is_nil(ast) do
    # Try to extract map update keys from the AST.
    # Pattern: %{tracks | key1: expr1, key2: expr2}
    # This gives us which tracks are modified.
    updated_keys = extract_map_update_keys(ast)

    if updated_keys != [] do
      # For each updated track, emit a primed assignment.
      # We use a simplified approach: compile the update expressions.
      Map.new(updated_keys, fn key ->
        key_str = Atom.to_string(key)
        # For now, emit a generic primed expression.
        # The full compilation would walk the update AST.
        {key_str, "#{key_str}'"}
      end)
    else
      # Can't determine which tracks are modified — mark all tracks as changed.
      state_space.variables
      |> Enum.reject(&(&1.name == "state" or &1.name == "event"))
      |> Map.new(fn var -> {var.name, "#{var.name}'"} end)
    end
  end

  defp build_track_primed(_, _), do: %{}

  # Extract keys from map update patterns like `%{tracks | key1: val, key2: val}`.
  defp extract_map_update_keys(ast) do
    case ast do
      # fn ... -> body end
      {:fn, _, [{:->, _, [_args, body]}]} ->
        extract_map_update_keys(body)

      # %{var | key: val, ...}
      {:%{}, _, [{:|, _, [_base | updates]}]} ->
        extract_keys_from_pairs(List.flatten(updates))

      # Block — check last expression.
      {:__block__, _, exprs} ->
        extract_map_update_keys(List.last(exprs))

      _ ->
        []
    end
  end

  defp extract_keys_from_pairs(pairs) do
    Enum.flat_map(pairs, fn
      {key, _val} when is_atom(key) -> [key]
      _ -> []
    end)
  end

  defp build_action_name(tag, source, target) do
    "#{camelize(tag)}From#{camelize(source)}To#{camelize(target)}"
  end

  defp resolve_next_state(:__same__, current), do: current
  defp resolve_next_state(state, _current), do: state

  defp message_tag(pattern) when is_atom(pattern), do: Atom.to_string(pattern)
  defp message_tag(pattern) when is_tuple(pattern), do: pattern |> elem(0) |> Atom.to_string()

  defp camelize(s) when is_binary(s) do
    s
    |> String.split("_")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join()
  end

  defp camelize(a) when is_atom(a), do: camelize(Atom.to_string(a))
end
