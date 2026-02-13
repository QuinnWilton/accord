defmodule Accord.TLA.ViolationReport do
  @moduledoc """
  Formats TLC model-checking violations as pentiment diagnostics.

  Converts a `TLCParser.violation()` map into a source-annotated error
  string using the protocol module's `__tla_span__/1` and `__ir__/0` to
  resolve source locations.

  ## Usage

      formatted = ViolationReport.format(violation, MyProtocol)

  ## Strict mode

  Pass `strict: true` to raise on missing spans or missing protocol
  exports. Intended for test environments.

      formatted = ViolationReport.format(violation, MyProtocol, strict: true)
  """

  alias Accord.TLA.TLCParser
  alias Accord.Violation.SpanValidation
  alias Pentiment.{Label, Report, Source}
  alias Pentiment.Span.Position

  @spec format(TLCParser.violation(), module(), keyword()) :: String.t()
  def format(violation, protocol_mod, opts \\ []) do
    strict? = Keyword.get(opts, :strict, false)

    if strict? do
      ensure_exports!(protocol_mod)
    end

    report =
      build_report(violation)
      |> add_source_label(violation, protocol_mod, opts)
      |> add_trace_labels(violation, protocol_mod, opts)
      |> add_trace_notes(violation)
      |> add_type_invariant_hint(violation, protocol_mod)

    render(report, protocol_mod)
  end

  # -- Report Building --

  defp build_report(%{kind: :invariant, property: property}) do
    Report.error("invariant #{property || "unknown"} violated")
  end

  defp build_report(%{kind: :action_property, property: property}) do
    Report.error("action property #{property || "unknown"} violated")
  end

  defp build_report(%{kind: :deadlock}) do
    Report.error("deadlock reached")
  end

  defp build_report(%{kind: :temporal}) do
    Report.error("temporal property violated")
  end

  # -- Source Labels --

  # Attach a primary label pointing at the violated property's definition.
  defp add_source_label(report, %{property: nil}, _mod, _opts), do: report

  defp add_source_label(report, %{property: property}, mod, opts) do
    strict? = Keyword.get(opts, :strict, false)

    case resolve_span(mod, property, strict?) do
      nil ->
        report

      span ->
        source_file = source_file(mod)

        if source_file do
          report
          |> Report.with_source(source_file)
          |> Report.with_label(Label.primary(span, "property defined here"))
        else
          report
        end
    end
  end

  # Attach a secondary label at the action span for the last trace step
  # (the violating step).
  defp add_trace_labels(report, %{trace: trace}, mod, opts) do
    strict? = Keyword.get(opts, :strict, false)
    last = List.last(trace)

    case last do
      %{action: action} when is_binary(action) ->
        case resolve_span(mod, action, strict?) do
          nil ->
            report

          span ->
            source_file = source_file(mod)

            if source_file do
              span = widen_transition_span(span, source_file)

              report
              |> Report.with_source(source_file)
              |> Report.with_label(Label.secondary(span, "violation occurs here"))
            else
              report
            end
        end

      _ ->
        report
    end
  end

  # Transition Position spans from the IR are narrow — they cover only the
  # message tag (e.g., `:release`). Widen to cover the full message spec
  # (e.g., `{:release, token :: pos_integer()}`) by reading the source line
  # and finding the enclosing tuple braces.
  defp widen_transition_span(%Position{} = span, source_file) do
    with true <- File.exists?(source_file),
         line when is_binary(line) <- read_source_line(source_file, span.start_line) do
      widen_to_message_spec(span, line)
    else
      _ -> span
    end
  end

  defp widen_transition_span(span, _source_file), do: span

  # Find the opening `{` before the span start and its matching `}`.
  defp widen_to_message_spec(%Position{} = span, line) do
    col0 = span.start_column - 1

    case find_open_brace(line, col0) do
      nil ->
        span

      open_idx ->
        case find_matching_close(line, open_idx) do
          nil ->
            span

          close_idx ->
            %Position{
              span
              | start_column: open_idx + 1,
                end_line: span.start_line,
                end_column: close_idx + 2
            }
        end
    end
  end

  # Scan backwards from `pos` (exclusive) to find the nearest `{`.
  # Stops if a non-whitespace, non-`{` character is encountered.
  defp find_open_brace(_line, pos) when pos <= 0, do: nil

  defp find_open_brace(line, pos) do
    case :binary.at(line, pos - 1) do
      ?{ -> pos - 1
      c when c in [?\s, ?\t] -> find_open_brace(line, pos - 1)
      _ -> nil
    end
  end

  # Find the `}` matching the `{` at `open_idx` via brace counting.
  defp find_matching_close(line, open_idx) do
    line
    |> binary_part(open_idx, byte_size(line) - open_idx)
    |> String.to_charlist()
    |> Enum.reduce_while({0, open_idx}, fn
      ?{, {depth, pos} -> {:cont, {depth + 1, pos + 1}}
      ?}, {1, pos} -> {:halt, {:found, pos}}
      ?}, {depth, pos} -> {:cont, {depth - 1, pos + 1}}
      _, {depth, pos} -> {:cont, {depth, pos + 1}}
    end)
    |> case do
      {:found, pos} -> pos
      _ -> nil
    end
  end

  defp read_source_line(path, line_number) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.at(line_number - 1)
  end

  # Add compact trace steps as notes.
  defp add_trace_notes(report, %{trace: trace}) do
    Enum.reduce(trace, report, fn entry, acc ->
      action_label =
        case entry.action do
          nil -> "Initial"
          name -> name
        end

      assignments =
        entry.assignments
        |> Enum.sort()
        |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{v}" end)

      note =
        if assignments == "" do
          "step #{entry.number}: #{action_label}"
        else
          "step #{entry.number}: #{action_label} -> #{assignments}"
        end

      Report.with_note(acc, note)
    end)
  end

  # -- TypeInvariant Overflow Detection --

  # When TypeInvariant fails, check if any variable exceeded its finite domain.
  # This is the most common root cause and the error is non-obvious without guidance.
  defp add_type_invariant_hint(
         report,
         %{kind: :invariant, property: "TypeInvariant"} = violation,
         mod
       ) do
    domains = fetch_domains(mod)
    last_assignments = last_trace_assignments(violation)

    overflows =
      Enum.flat_map(last_assignments, fn {var_name, value_str} ->
        with domain_str when is_binary(domain_str) <- Map.get(domains, var_name),
             {lo, hi} <- parse_range_domain(domain_str),
             value when is_integer(value) <- parse_tla_integer(value_str),
             true <- value < lo or value > hi do
          [{var_name, value, domain_str}]
        else
          _ -> []
        end
      end)

    case overflows do
      [] ->
        report

      _ ->
        report
        |> add_overflow_notes(overflows)
        |> add_overflow_help(overflows)
    end
  end

  defp add_type_invariant_hint(report, _violation, _mod), do: report

  defp fetch_domains(mod) do
    if function_exported?(mod, :__tla_domains__, 0) do
      mod.__tla_domains__()
    else
      %{}
    end
  end

  defp last_trace_assignments(%{trace: [_ | _] = trace}) do
    List.last(trace).assignments
  end

  defp last_trace_assignments(_), do: %{}

  defp add_overflow_notes(report, overflows) do
    Enum.reduce(overflows, report, fn {var_name, value, domain_str}, acc ->
      Report.with_note(
        acc,
        "variable '#{var_name}' has value #{value}, which is outside its domain #{domain_str}"
      )
    end)
  end

  defp add_overflow_help(report, overflows) do
    Enum.reduce(overflows, report, fn {var_name, _value, _domain_str}, acc ->
      acc
      |> Report.with_help(
        "widen the domain in `.accord_model.exs` — `domains: %{#{var_name}: 0..100}`"
      )
      |> Report.with_help(
        "or bound exploration with a state constraint — `state_constraint: \"#{var_name} =< N\"`"
      )
    end)
  end

  # Parse "N..M" range domains. Returns nil for non-range domains (sets, STRING, etc.).
  defp parse_range_domain(domain_str) do
    case Regex.run(~r/^(-?\d+)\.\.(-?\d+)$/, domain_str) do
      [_, lo, hi] -> {String.to_integer(lo), String.to_integer(hi)}
      _ -> nil
    end
  end

  # Parse a TLA+ integer value string.
  defp parse_tla_integer(value_str) do
    case Integer.parse(String.trim(value_str)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  # -- Rendering --

  defp render(report, mod) do
    source_file = source_file(mod)

    cond do
      source_file != nil and File.exists?(source_file) ->
        source = Source.from_file(source_file)
        Pentiment.format(report, source)

      source_file != nil ->
        Pentiment.format(report, nil)

      true ->
        Pentiment.format(report, nil)
    end
  end

  # -- Helpers --

  defp resolve_span(mod, identifier, strict?) do
    if function_exported?(mod, :__tla_span__, 1) do
      span = mod.__tla_span__(identifier)

      cond do
        span != nil and strict? ->
          SpanValidation.validate_span!(span, "TLA+ identifier #{inspect(identifier)}")

        span != nil ->
          span

        strict? ->
          raise ArgumentError,
                "missing span for TLA+ identifier #{inspect(identifier)}"

        true ->
          nil
      end
    else
      if strict? do
        raise ArgumentError,
              "#{inspect(mod)} does not export __tla_span__/1"
      end

      nil
    end
  end

  defp source_file(mod) do
    if function_exported?(mod, :__ir__, 0) do
      mod.__ir__().source_file
    else
      nil
    end
  end

  defp ensure_exports!(mod) do
    unless function_exported?(mod, :__tla_span__, 1) do
      raise ArgumentError, "#{inspect(mod)} does not export __tla_span__/1"
    end

    unless function_exported?(mod, :__ir__, 0) do
      raise ArgumentError, "#{inspect(mod)} does not export __ir__/0"
    end
  end
end
