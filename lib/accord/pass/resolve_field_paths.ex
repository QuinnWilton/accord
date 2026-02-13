defmodule Accord.Pass.ResolveFieldPaths do
  @moduledoc """
  Resolves `by:` field paths in ordered and correspondence checks.

  For each check with a `by:` field, looks up the parameter name in the
  relevant transition's `message_arg_names` and computes a tuple position
  index plus any remaining nested map/struct keys.

  Runs after `ValidateProperties` so event tags are already validated.
  """

  alias Accord.IR
  alias Pentiment.Report

  import Accord.Pass.Helpers

  @spec run(IR.t()) :: {:ok, IR.t()} | {:error, [Report.t()]}
  def run(%IR{} = ir) do
    transitions_by_tag = collect_transitions_by_tag(ir)

    {properties, errors} =
      Enum.map_reduce(ir.properties, [], fn property, acc ->
        {checks, new_acc} =
          Enum.map_reduce(property.checks, acc, fn check, inner_acc ->
            resolve_check(check, property, transitions_by_tag, ir, inner_acc)
          end)

        {%{property | checks: checks}, new_acc}
      end)

    case errors do
      [] -> {:ok, %{ir | properties: properties}}
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  # Ordered: resolve the single `by:` path against the event's transition.
  defp resolve_check(%IR.Check{kind: :ordered} = check, property, transitions, ir, errors) do
    path = normalize_path(check.spec.by)
    event = check.spec.event

    case resolve_path(path, event, transitions, property, ir) do
      {:ok, extract} ->
        spec = Map.put(check.spec, :extract, extract)
        {%{check | spec: spec}, errors}

      {:error, report} ->
        {check, [report | errors]}
    end
  end

  # Correspondence with `by:`: resolve path in open event and each close event.
  defp resolve_check(%IR.Check{kind: :correspondence} = check, property, transitions, ir, errors)
       when check.spec.by != nil do
    path = normalize_path(check.spec.by)

    with {:ok, open_extract} <- resolve_path(path, check.spec.open, transitions, property, ir),
         {:ok, close_extracts} <-
           resolve_close_paths(path, check.spec.close, transitions, property, ir) do
      spec =
        check.spec
        |> Map.put(:open_extract, open_extract)
        |> Map.put(:close_extracts, close_extracts)

      {%{check | spec: spec}, errors}
    else
      {:error, report} ->
        {check, [report | errors]}
    end
  end

  # All other checks pass through unchanged.
  defp resolve_check(check, _property, _transitions, _ir, errors) do
    {check, errors}
  end

  defp resolve_close_paths(path, close_events, transitions, property, ir) do
    Enum.reduce_while(close_events, {:ok, %{}}, fn event, {:ok, acc} ->
      case resolve_path(path, event, transitions, property, ir) do
        {:ok, extract} -> {:cont, {:ok, Map.put(acc, event, extract)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp resolve_path(path, event, transitions, property, ir) do
    [param_name | nested_keys] = path

    case Map.get(transitions, event) do
      nil ->
        report =
          Report.error("field path references unknown event :#{event}")
          |> Report.with_code("E035")
          |> maybe_add_source(ir.source_file)
          |> maybe_add_span_label(
            property.span,
            "event :#{event} does not appear in any transition"
          )

        {:error, report}

      transition_list ->
        # Use the first transition with arg names (they should all have the same arg names
        # for the same message tag).
        transition = List.first(transition_list)
        arg_names = transition.message_arg_names

        case find_arg_position(arg_names, to_string(param_name)) do
          nil ->
            report =
              Report.error("field :#{param_name} not found in :#{event} message parameters")
              |> Report.with_code("E036")
              |> maybe_add_source(ir.source_file)
              |> maybe_add_span_label(
                property.span,
                ":#{param_name} is not a parameter of :#{event}"
              )
              |> Report.with_help(
                "available parameters are: #{Enum.map_join(arg_names, ", ", &":#{&1}")}"
              )

            {:error, report}

          index ->
            # Position in the tuple is index + 1 (index 0 is the tag).
            {:ok, %{position: index + 1, path: nested_keys}}
        end
    end
  end

  defp find_arg_position(arg_names, name) do
    Enum.find_index(arg_names, fn arg_name ->
      arg_name == name or arg_name == "_#{name}"
    end)
  end

  defp normalize_path(path) when is_atom(path), do: [path]
  defp normalize_path(path) when is_list(path), do: path

  # Collects all transitions grouped by message tag.
  defp collect_transitions_by_tag(%IR{states: states, anystate: anystate}) do
    all_transitions =
      Enum.flat_map(states, fn {_name, state} -> state.transitions end) ++ anystate

    Enum.group_by(all_transitions, &message_tag/1)
  end
end
