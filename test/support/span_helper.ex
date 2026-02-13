defmodule Accord.Test.SpanHelper do
  @moduledoc false

  # Resolves a span against a source to extract the matched text.
  # Used by compiled_span_test.exs to assert span correctness.

  alias Pentiment.Source
  alias Pentiment.Span.{Position, Search}

  @spec resolve_text(Position.t() | Search.t(), Source.t()) :: String.t()
  def resolve_text(%Search{} = span, source) do
    resolved = Search.resolve(span, source)
    resolve_text(resolved, source)
  end

  def resolve_text(%Position{end_column: ec} = span, source) when is_integer(ec) do
    line_text = Source.line(source, span.start_line)
    String.slice(line_text, span.start_column - 1, ec - span.start_column)
  end

  def resolve_text(%Position{} = span, source) do
    line_text = Source.line(source, span.start_line)
    String.slice(line_text, span.start_column - 1, String.length(line_text))
  end
end
