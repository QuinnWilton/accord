defmodule Accord.TLA.SpanMap do
  @moduledoc """
  Maps TLA+ identifiers back to source spans.

  Built from the IR and compiled TLA+ artifacts. Used by `mix accord.check`
  to render TLC counterexamples pointing at the original Elixir source.

  Covers:
  - **Action names** → transition spans (e.g., `"AcquireFromUnlockedToLocked"`)
  - **Variable names** → track/state spans (e.g., `"fence_token"`, `"state"`)
  - **State names** → state declaration spans (e.g., `"unlocked"`)
  - **Property names** → property declaration spans (e.g., `"MonotonicTokens"`)
  """

  alias Accord.IR
  alias Accord.TLA.Action

  @type t :: %{String.t() => Pentiment.Span.t()}

  @doc """
  Builds a span map from the IR and the compiled TLA+ actions.

  Actions carry generated names (e.g., `"AcquireFromUnlockedToLocked"`)
  that must be mapped back to the originating transition's span. Since
  action names are derived from message tag + source/target state, we
  match actions to transitions by `(source_state, message_tag)`.
  """
  @spec build(IR.t(), [Action.t()]) :: t()
  def build(%IR{} = ir, actions) do
    state_spans = build_state_spans(ir)
    variable_spans = build_variable_spans(ir)
    property_spans = build_property_spans(ir)
    action_spans = build_action_spans(ir, actions)

    state_spans
    |> Map.merge(variable_spans)
    |> Map.merge(property_spans)
    |> Map.merge(action_spans)
  end

  # Map state name strings to state declaration spans.
  defp build_state_spans(%IR{states: states}) do
    for {name, state} <- states, state.span != nil, into: %{} do
      {Atom.to_string(name), state.span}
    end
  end

  # Map variable name strings to track/initial-state spans.
  # The "state" variable doesn't have a span — it's implicit.
  defp build_variable_spans(%IR{tracks: tracks}) do
    for track <- tracks, track.span != nil, into: %{} do
      {Atom.to_string(track.name), track.span}
    end
  end

  # Map CamelCase property names to property declaration spans.
  # Also maps state-qualified names for local invariants (e.g.,
  # "HolderConsistencyUnlocked" from `:holder_consistency` + `:unlocked`).
  defp build_property_spans(%IR{properties: properties}) do
    base =
      for prop <- properties, prop.span != nil do
        {camelize(prop.name), prop.span}
      end

    qualified =
      for prop <- properties,
          prop.span != nil,
          check <- prop.checks,
          check.kind == :local_invariant do
        {camelize(prop.name) <> camelize(check.spec.state), prop.span}
      end

    Map.new(base ++ qualified)
  end

  # Map action names to their originating transition spans.
  #
  # Actions are derived from transitions. Each action carries the
  # source_state and message_tag, which we use to find the matching
  # transition (and its span) in the IR.
  defp build_action_spans(%IR{} = ir, actions) do
    # Build a lookup from {source_state_atom, message_tag_string} → span.
    transition_lookup = build_transition_lookup(ir)

    for action <- actions, into: %{} do
      source_atom = String.to_existing_atom(action.source_state)
      key = {source_atom, action.message_tag}

      span = Map.get(transition_lookup, key)
      {action.name, span}
    end
    |> Enum.reject(fn {_name, span} -> is_nil(span) end)
    |> Map.new()
  end

  # Build a lookup of {state_name_atom, message_tag_string} → transition span.
  # Includes anystate transitions mapped to each non-terminal state.
  defp build_transition_lookup(%IR{} = ir) do
    state_transitions =
      for {state_name, state} <- ir.states,
          transition <- state.transitions,
          transition.span != nil do
        tag = message_tag(transition.message_pattern)
        {{state_name, tag}, transition.span}
      end

    anystate_transitions =
      for {state_name, state} <- ir.states,
          !state.terminal,
          transition <- ir.anystate,
          transition.span != nil do
        tag = message_tag(transition.message_pattern)
        {{state_name, tag}, transition.span}
      end

    Map.new(state_transitions ++ anystate_transitions)
  end

  defp message_tag(pattern) when is_atom(pattern), do: Atom.to_string(pattern)
  defp message_tag(pattern) when is_tuple(pattern), do: pattern |> elem(0) |> Atom.to_string()

  defp camelize(name) when is_atom(name) do
    name
    |> Atom.to_string()
    |> String.split("_")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join()
  end
end
