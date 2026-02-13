defmodule Accord.Violation.SpanValidation do
  @moduledoc false

  # Validates pentiment spans at diagnostic-build time. Raises on missing or
  # malformed spans when strict mode is enabled, catching span regressions in
  # tests rather than silently producing degraded output.

  alias Pentiment.Span.{Position, Search}

  @spec validate_span!(Position.t() | Search.t() | nil, String.t()) ::
          Position.t() | Search.t()
  def validate_span!(nil, context) do
    raise ArgumentError, "missing span: #{context}"
  end

  def validate_span!(%Position{} = span, context) do
    unless span.start_line >= 1 do
      raise ArgumentError, "invalid span start_line #{span.start_line}: #{context}"
    end

    unless span.start_column >= 1 do
      raise ArgumentError, "invalid span start_column #{span.start_column}: #{context}"
    end

    if span.end_line != nil and span.end_column != nil do
      if span.end_line == span.start_line and span.end_column <= span.start_column do
        raise ArgumentError,
              "invalid span range: end_column (#{span.end_column}) must be > " <>
                "start_column (#{span.start_column}) on same line: #{context}"
      end
    end

    span
  end

  def validate_span!(%Search{} = span, context) do
    unless span.line >= 1 do
      raise ArgumentError, "invalid search span line #{span.line}: #{context}"
    end

    unless is_binary(span.pattern) and byte_size(span.pattern) > 0 do
      raise ArgumentError, "invalid search span pattern: #{context}"
    end

    span
  end

  def validate_span!(other, context) do
    raise ArgumentError, "unexpected span type #{inspect(other)}: #{context}"
  end
end
