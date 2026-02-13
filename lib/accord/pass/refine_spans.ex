defmodule Accord.Pass.RefineSpans do
  @moduledoc """
  Narrows coarse macro-captured spans to point at specific tokens.

  The DSL macros capture spans at the macro call keyword (e.g., `state`,
  `on`, `track`). This pass reads the source file and narrows each span
  to the specific token relevant to that IR construct — state names,
  message patterns, track names, etc.
  """

  alias Accord.IR
  alias Pentiment.Span

  @spec run(IR.t()) :: {:ok, IR.t()}
  def run(%IR{source_file: nil} = ir), do: {:ok, ir}

  def run(%IR{source_file: source_file} = ir) do
    case File.read(source_file) do
      {:ok, content} ->
        lines = content |> String.split("\n") |> List.to_tuple()
        ir = refine_ir(ir, lines)
        {:ok, ir}

      {:error, _} ->
        {:ok, ir}
    end
  end

  defp refine_ir(ir, lines) do
    states =
      Map.new(ir.states, fn {name, state} ->
        {name, refine_state(state, lines)}
      end)

    anystate = Enum.map(ir.anystate, &refine_transition(&1, lines))

    %{ir | states: states, anystate: anystate}
  end

  defp refine_state(%{span: nil} = state, _lines), do: state

  defp refine_state(state, lines) do
    span = refine_span_to_token(state.span, lines, Atom.to_string(state.name))

    transitions = Enum.map(state.transitions, &refine_transition(&1, lines))

    %{state | span: span, transitions: transitions}
  end

  defp refine_transition(%{span: nil} = transition, _lines), do: transition

  defp refine_transition(transition, lines) do
    target = message_pattern_string(transition.message_pattern)
    span = refine_span_to_token(transition.span, lines, target)
    %{transition | span: span}
  end

  defp message_pattern_string(pattern) when is_atom(pattern), do: Atom.to_string(pattern)

  defp message_pattern_string(pattern) when is_tuple(pattern) do
    tag = elem(pattern, 0)
    if is_atom(tag), do: Atom.to_string(tag), else: nil
  end

  defp message_pattern_string(_), do: nil

  defp refine_span_to_token(nil, _lines, _target), do: nil
  defp refine_span_to_token(span, _lines, nil), do: span

  defp refine_span_to_token(%Span.Position{start_line: line} = span, lines, target) do
    if line > 0 and line <= tuple_size(lines) do
      source_line = elem(lines, line - 1)
      search_target = ":#{target}"

      case :binary.match(source_line, search_target) do
        {byte_offset, _length} ->
          # Convert byte offset to column (1-indexed).
          col = byte_offset + 1
          display_len = Pentiment.Elixir.value_display_length(String.to_atom(target))

          %Span.Position{
            start_line: line,
            start_column: col,
            end_line: line,
            end_column: col + display_len
          }

        :nomatch ->
          span
      end
    else
      span
    end
  end

  defp refine_span_to_token(span, _lines, _target), do: span
end
