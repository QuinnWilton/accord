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
              span = widen_transition_span(span)

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
  # message tag (e.g., `{:release,`). Widen to include the `on ` keyword
  # that precedes the message spec for a more complete highlight.
  defp widen_transition_span(%Position{} = span) when span.start_column > 3 do
    %Position{span | start_column: span.start_column - 3}
  end

  defp widen_transition_span(span), do: span

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
