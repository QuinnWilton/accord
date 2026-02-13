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

    # Build bindings for update fn params and additional reply existentials.
    {reply_existentials, update_bindings} =
      build_update_bindings(transition, branch, existential_vars, config)

    # Constraint precondition from where clause.
    {constraint_existentials, constraint_precondition} =
      build_constraint(branch, reply_existentials, config)

    existential_vars = existential_vars ++ reply_existentials ++ constraint_existentials

    # Track updates from update AST.
    track_primed = build_track_primed(transition, branch, state_space, update_bindings)

    # Event variable.
    event_primed =
      if state_space.has_event_var do
        %{"event" => ~s("#{tag}")}
      else
        %{}
      end

    # Correspondence counter updates.
    correspondence_primed =
      build_correspondence_primed(tag, source, target, state_space)

    all_primed =
      primed
      |> Map.merge(track_primed)
      |> Map.merge(event_primed)
      |> Map.merge(correspondence_primed)

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
      preconditions: preconditions ++ guard_precondition ++ constraint_precondition,
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

  defp build_track_primed(%Transition{update: nil}, _branch, _state_space, _bindings), do: %{}

  defp build_track_primed(%Transition{update: %{ast: ast}}, branch, _state_space, bindings)
       when not is_nil(ast) do
    # Try to extract map update key-value pairs from the AST,
    # resolving case expressions against the branch's reply type.
    update_pairs = extract_map_update_pairs(ast, branch)

    Map.new(update_pairs, fn {key, val_ast} ->
      key_str = Atom.to_string(key)

      tla_val =
        case GuardCompiler.compile(val_ast, bindings) do
          {:ok, expr} -> expr
          {:partial, expr, _} -> expr
        end

      {key_str, tla_val}
    end)
  end

  defp build_track_primed(_, _, _, _), do: %{}

  # Extract key-value pairs from map update patterns like `%{tracks | key1: val, key2: val}`.
  # Resolves case expressions against the branch's reply type.
  defp extract_map_update_pairs(ast, branch) do
    case ast do
      # fn ... -> body end
      {:fn, _, [{:->, _, [_args, body]}]} ->
        extract_map_update_pairs(body, branch)

      # %{var | key: val, ...}
      {:%{}, _, [{:|, _, [_base | updates]}]} ->
        pairs_from_keyword(List.flatten(updates))

      # case reply do :ok -> body1; _ -> body2 end
      # Resolve against the branch's reply type.
      {:case, _, [_expr, [do: clauses]]} ->
        resolve_case_for_branch(clauses, branch)

      # Block — check last expression.
      {:__block__, _, exprs} ->
        extract_map_update_pairs(List.last(exprs), branch)

      _ ->
        []
    end
  end

  # Finds the matching case clause for the branch's reply type
  # and extracts map update pairs from that arm's body.
  defp resolve_case_for_branch(clauses, branch) do
    reply_type = branch.reply_type

    # Find the first matching clause.
    matching_clause =
      Enum.find(clauses, fn {:->, _, [[pattern], _body]} ->
        case_pattern_matches_reply_type?(pattern, reply_type)
      end)

    case matching_clause do
      {:->, _, [[_pattern], body]} ->
        extract_map_update_pairs(body, branch)

      nil ->
        # No match found — try wildcard clause.
        wildcard =
          Enum.find(clauses, fn {:->, _, [[pattern], _body]} ->
            wildcard_pattern?(pattern)
          end)

        case wildcard do
          {:->, _, [[_pattern], body]} ->
            extract_map_update_pairs(body, branch)

          nil ->
            []
        end
    end
  end

  # Checks if a case pattern matches the branch's reply type.
  defp case_pattern_matches_reply_type?(pattern, {:literal, value}) do
    pattern == value
  end

  defp case_pattern_matches_reply_type?({tag, _}, {:tagged, tag, _inner}) do
    true
  end

  defp case_pattern_matches_reply_type?(_, _), do: false

  # Checks if a pattern is a wildcard (matches anything).
  defp wildcard_pattern?({:_, _, _}), do: true
  defp wildcard_pattern?({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: true
  defp wildcard_pattern?(_), do: false

  defp pairs_from_keyword(pairs) do
    Enum.flat_map(pairs, fn
      {key, val} when is_atom(key) -> [{key, val}]
      _ -> []
    end)
  end

  # Builds bindings from the update fn's param names to TLA+ identifiers.
  # Maps message params to existing existential vars and creates new
  # existential vars for reply params.
  defp build_update_bindings(%Transition{update: nil}, _branch, _existentials, _config) do
    {[], %{}}
  end

  defp build_update_bindings(%Transition{update: %{ast: ast}}, branch, existentials, config)
       when not is_nil(ast) do
    case ast do
      {:fn, _, [{:->, _, [[msg_pat, reply_pat, _tracks_var], _body]}]} ->
        # Map update fn's message params to existing existential vars by position.
        msg_params = extract_pattern_params(msg_pat)
        msg_bindings = zip_to_existentials(msg_params, existentials)

        # Only create reply existentials when the pattern destructures the reply
        # (tagged tuple pattern), not when it's a bare variable.
        {reply_existentials, reply_bindings} =
          if destructured_pattern?(reply_pat) do
            reply_params = extract_pattern_params(reply_pat)
            reply_types = extract_reply_inner_types(branch.reply_type)
            build_reply_existentials(reply_params, reply_types, config)
          else
            {[], %{}}
          end

        {reply_existentials, Map.merge(msg_bindings, reply_bindings)}

      _ ->
        {[], %{}}
    end
  end

  defp build_update_bindings(_, _, _, _), do: {[], %{}}

  # Compiles a branch constraint (where clause) into a TLA+ precondition.
  # Maps the constraint fn's reply params to existing reply existential vars,
  # or creates new ones if the branch has no update fn.
  defp build_constraint(%{constraint: nil}, _reply_existentials, _config), do: {[], []}

  defp build_constraint(
         %{constraint: %{ast: ast}, reply_type: reply_type},
         reply_existentials,
         config
       ) do
    case ast do
      {:fn, _, [{:->, _, [[reply_pat, _tracks_var], body]}]} ->
        reply_params = extract_pattern_params(reply_pat)

        {extra_existentials, bindings} =
          if reply_existentials != [] do
            # Map constraint params to existing reply existentials by position.
            {[], zip_to_existentials(reply_params, reply_existentials)}
          else
            # No update fn created reply existentials — create from constraint.
            reply_types = extract_reply_inner_types(reply_type)
            build_reply_existentials(reply_params, reply_types, config)
          end

        case GuardCompiler.compile(body, bindings) do
          {:ok, tla} -> {extra_existentials, [tla]}
          {:partial, tla, _} -> {extra_existentials, [tla]}
        end

      _ ->
        {[], []}
    end
  end

  # Returns true if the pattern destructures into components (tagged tuple),
  # false if it's a bare variable binding.
  defp destructured_pattern?({name, meta, ctx})
       when is_atom(name) and is_list(meta) and is_atom(ctx),
       do: false

  defp destructured_pattern?(_), do: true

  # Extracts variable names from pattern AST, skipping tags and underscored vars.
  defp extract_pattern_params({name, meta, ctx})
       when is_atom(name) and is_list(meta) and is_atom(ctx) do
    name_str = Atom.to_string(name)
    if String.starts_with?(name_str, "_"), do: [], else: [name]
  end

  defp extract_pattern_params({tag, inner}) when is_atom(tag) do
    # 2-tuple pattern like {:ok, val} — skip tag, extract from inner.
    extract_pattern_params(inner)
  end

  defp extract_pattern_params({:{}, _meta, [_tag | rest]}) do
    # 3+ tuple pattern — skip tag, extract from rest.
    Enum.flat_map(rest, &extract_pattern_params/1)
  end

  defp extract_pattern_params(_), do: []

  # Maps param names to existing existential TLA+ var names by position.
  defp zip_to_existentials(param_names, existential_vars) do
    param_names
    |> Enum.zip(existential_vars)
    |> Map.new(fn {name, {tla_var, _domain}} -> {name, tla_var} end)
  end

  # Extracts the inner type atoms from a reply type spec.
  defp extract_reply_inner_types({:tagged, _tag, inner_type}), do: [inner_type]
  defp extract_reply_inner_types(_), do: []

  # Creates existential vars for reply parameters.
  defp build_reply_existentials(params, types, config) do
    {vars_rev, bindings} =
      params
      |> Enum.zip(types)
      |> Enum.reduce({[], %{}}, fn {name, type}, {vars_acc, bindings_acc} ->
        tla_var = "reply_#{name}"
        domain = ModelConfig.resolve_domain(config, name, type)
        domain_tla = ModelConfig.domain_to_tla(domain)
        {[{tla_var, domain_tla} | vars_acc], Map.put(bindings_acc, name, tla_var)}
      end)

    {Enum.reverse(vars_rev), bindings}
  end

  # Builds primed assignments for correspondence counter variables.
  defp build_correspondence_primed(tag, source, target, %StateSpace{
         correspondences: correspondences
       }) do
    Enum.reduce(correspondences, %{}, fn corr, acc ->
      open_tag = Atom.to_string(corr.open)
      close_tags = Enum.map(corr.close, &Atom.to_string/1)

      cond do
        tag == open_tag and source != target ->
          Map.put(acc, corr.counter_var, "(#{corr.counter_var} + 1)")

        tag in close_tags and source != target ->
          Map.put(acc, corr.counter_var, "(#{corr.counter_var} - 1)")

        true ->
          acc
      end
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
