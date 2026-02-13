defmodule Accord.Pass.Helpers do
  @moduledoc """
  Shared helpers for validation pass modules.

  These functions add optional source and span metadata to pentiment reports,
  and extract message tags from IR transition structs.
  """

  alias Pentiment.{Label, Report}

  @spec maybe_add_source(Report.t(), Pentiment.Source.t() | nil) :: Report.t()
  def maybe_add_source(report, nil), do: report
  def maybe_add_source(report, source), do: Report.with_source(report, source)

  @spec maybe_add_span_label(Report.t(), Pentiment.Span.t() | nil, String.t()) :: Report.t()
  def maybe_add_span_label(report, nil, _msg), do: report

  def maybe_add_span_label(report, span, msg) do
    Report.with_label(report, Label.primary(span, msg))
  end

  @doc """
  Extracts the message tag from an IR transition's `message_pattern`.

  Note: this operates on IR transition structs. The `message_tag/1` functions
  in `TransitionTable` and `Monitor` operate on raw runtime messages and are
  semantically different.
  """
  @spec message_tag(%{message_pattern: atom() | tuple()}) :: atom()
  def message_tag(%{message_pattern: pattern}) when is_atom(pattern), do: pattern
  def message_tag(%{message_pattern: pattern}) when is_tuple(pattern), do: elem(pattern, 0)
end
