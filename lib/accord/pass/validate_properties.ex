defmodule Accord.Pass.ValidateProperties do
  @moduledoc """
  Validates that property check specs reference valid protocol elements.

  Checks:
  - `:bounded` checks reference a track that exists in `ir.tracks`.
  - `:correspondence` checks reference an open event that appears in some
    transition's `message_pattern`.
  - `:local_invariant` checks reference a state that exists in `ir.states`.
  - `:reachable` checks reference a target state that exists in `ir.states`.
  - `:precedence` checks reference target and required states that both
    exist in `ir.states`.
  """

  alias Accord.IR
  alias Pentiment.Report

  import Accord.Pass.Helpers

  @spec run(IR.t()) :: {:ok, IR.t()} | {:error, [Report.t()]}
  def run(%IR{} = ir) do
    track_names = Enum.map(ir.tracks, & &1.name)
    state_names = Map.keys(ir.states)
    message_tags = collect_message_tags(ir)

    errors =
      Enum.reduce(ir.properties, [], fn property, acc ->
        Enum.reduce(property.checks, acc, fn check, inner_acc ->
          validate_check(check, ir, track_names, state_names, message_tags, inner_acc)
        end)
      end)

    case errors do
      [] -> {:ok, ir}
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  defp validate_check(%IR.Check{kind: :bounded} = check, ir, track_names, _states, _tags, errors) do
    track = check.spec[:track]

    if track in track_names do
      errors
    else
      report =
        Report.error("bounded check references undefined track :#{track}")
        |> Report.with_code("E030")
        |> maybe_add_source(ir.source_file)
        |> maybe_add_span_label(check.span, "track :#{track} is not defined")
        |> Report.with_help("defined tracks are: #{Enum.map_join(track_names, ", ", &":#{&1}")}")

      [report | errors]
    end
  end

  defp validate_check(
         %IR.Check{kind: :correspondence} = check,
         ir,
         _tracks,
         _states,
         tags,
         errors
       ) do
    open_event = check.spec[:open]

    if open_event in tags do
      errors
    else
      report =
        Report.error("correspondence check references undefined open event :#{open_event}")
        |> Report.with_code("E031")
        |> maybe_add_source(ir.source_file)
        |> maybe_add_span_label(
          check.span,
          "event :#{open_event} does not appear in any transition"
        )
        |> Report.with_help(
          "defined message tags are: #{Enum.map_join(Enum.sort(tags), ", ", &":#{&1}")}"
        )

      [report | errors]
    end
  end

  defp validate_check(
         %IR.Check{kind: :local_invariant} = check,
         ir,
         _tracks,
         state_names,
         _tags,
         errors
       ) do
    state = check.spec[:state]

    if state in state_names do
      errors
    else
      report =
        Report.error("local_invariant check references undefined state :#{state}")
        |> Report.with_code("E032")
        |> maybe_add_source(ir.source_file)
        |> maybe_add_span_label(check.span, "state :#{state} is not defined")
        |> Report.with_help("defined states are: #{Enum.map_join(state_names, ", ", &":#{&1}")}")

      [report | errors]
    end
  end

  defp validate_check(
         %IR.Check{kind: :reachable} = check,
         ir,
         _tracks,
         state_names,
         _tags,
         errors
       ) do
    target = check.spec[:target]

    if target in state_names do
      errors
    else
      report =
        Report.error("reachable check references undefined state :#{target}")
        |> Report.with_code("E033")
        |> maybe_add_source(ir.source_file)
        |> maybe_add_span_label(check.span, "state :#{target} is not defined")
        |> Report.with_help("defined states are: #{Enum.map_join(state_names, ", ", &":#{&1}")}")

      [report | errors]
    end
  end

  defp validate_check(
         %IR.Check{kind: :precedence} = check,
         ir,
         _tracks,
         state_names,
         _tags,
         errors
       ) do
    target = check.spec[:target]
    required = check.spec[:required]

    errors
    |> validate_precedence_state(target, "target", check, ir, state_names)
    |> validate_precedence_state(required, "required", check, ir, state_names)
  end

  defp validate_check(_check, _ir, _tracks, _states, _tags, errors), do: errors

  defp validate_precedence_state(errors, state, role, check, ir, state_names) do
    if state in state_names do
      errors
    else
      report =
        Report.error("precedence check references undefined #{role} state :#{state}")
        |> Report.with_code("E034")
        |> maybe_add_source(ir.source_file)
        |> maybe_add_span_label(check.span, "#{role} state :#{state} is not defined")
        |> Report.with_help("defined states are: #{Enum.map_join(state_names, ", ", &":#{&1}")}")

      [report | errors]
    end
  end

  # Collects all message tags from transitions across all states and anystate.
  defp collect_message_tags(%IR{states: states, anystate: anystate}) do
    all_transitions =
      Enum.flat_map(states, fn {_name, state} -> state.transitions end) ++ anystate

    all_transitions
    |> Enum.map(&message_tag/1)
    |> MapSet.new()
  end
end
