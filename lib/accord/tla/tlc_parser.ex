defmodule Accord.TLA.TLCParser do
  @moduledoc """
  Parses TLC model checker stdout into structured results.

  Handles success output, invariant violations, liveness failures,
  and deadlock traces. Used by `mix accord.check` to extract
  counterexamples and map them back to source spans.
  """

  @type state_entry :: %{
          number: pos_integer(),
          action: String.t() | nil,
          assignments: %{String.t() => String.t()}
        }

  @type trace :: [state_entry()]

  @type stats :: %{
          states_generated: non_neg_integer(),
          distinct_states: non_neg_integer(),
          depth: non_neg_integer() | nil
        }

  @type violation :: %{
          kind: :invariant | :deadlock | :temporal | :action_property,
          property: String.t() | nil,
          trace: trace()
        }

  @type result ::
          {:ok, stats()}
          | {:error, violation(), stats()}

  @doc """
  Parses raw TLC stdout into a structured result.
  """
  @spec parse(String.t()) :: result()
  def parse(output) do
    lines = String.split(output, "\n")
    stats = parse_stats(lines)

    case classify_output(lines) do
      :success ->
        {:ok, stats}

      {:invariant, property} ->
        trace = parse_trace(lines)
        {:error, %{kind: :invariant, property: property, trace: trace}, stats}

      {:action_property, property} ->
        trace = parse_trace(lines)
        {:error, %{kind: :action_property, property: property, trace: trace}, stats}

      :deadlock ->
        trace = parse_trace(lines)
        {:error, %{kind: :deadlock, property: nil, trace: trace}, stats}

      :temporal ->
        trace = parse_trace(lines)
        {:error, %{kind: :temporal, property: nil, trace: trace}, stats}

      :unknown ->
        {:error, %{kind: :invariant, property: nil, trace: []}, stats}
    end
  end

  # Single-pass classification of TLC output.
  defp classify_output(lines) do
    Enum.reduce_while(lines, :unknown, fn line, acc ->
      cond do
        String.contains?(line, "Model checking completed. No error has been found.") ->
          {:halt, :success}

        match = Regex.run(~r/^Error: Invariant (.+) is violated/, line) ->
          {:halt, {:invariant, Enum.at(match, 1)}}

        match = Regex.run(~r/^Error: Action property (.+) is violated/, line) ->
          {:halt, {:action_property, Enum.at(match, 1)}}

        String.contains?(line, "Error: Deadlock reached.") ->
          {:halt, :deadlock}

        String.contains?(line, "Error: Temporal properties were violated.") ->
          {:halt, :temporal}

        true ->
          {:cont, acc}
      end
    end)
  end

  # -- Trace parsing --

  @doc """
  Parses a counterexample trace from TLC output lines.

  Handles both regular states (`State N: <action>`) and back-to states
  (`Back to state N: <action>`) used in liveness counterexamples.
  """
  @spec parse_trace([String.t()]) :: trace()
  def parse_trace(lines) do
    # Find the start of the trace — lines beginning with "State 1:".
    lines
    |> Enum.drop_while(fn line ->
      not Regex.match?(~r/^State 1:/, String.trim(line))
    end)
    |> split_into_state_blocks()
    |> Enum.map(&parse_state_block/1)
  end

  # Split lines into groups, each starting with "State N:" or "Back to state N:".
  # Builds lists in reverse (prepending) and reverses at the end.
  defp split_into_state_blocks(lines) do
    {blocks, current} =
      Enum.reduce(lines, {[], []}, fn line, {blocks, current} ->
        trimmed = String.trim(line)

        cond do
          Regex.match?(~r/^State \d+:/, trimmed) ->
            if current == [] do
              {blocks, [trimmed]}
            else
              {[Enum.reverse(current) | blocks], [trimmed]}
            end

          Regex.match?(~r/^Back to state \d+:/, trimmed) ->
            if current == [] do
              {blocks, [trimmed]}
            else
              {[Enum.reverse(current) | blocks], [trimmed]}
            end

          # Stop at non-trace lines (stats, empty lines after trace).
          trimmed == "" and current != [] ->
            {[Enum.reverse(current) | blocks], []}

          # Assignment lines or continuation.
          String.starts_with?(trimmed, "/\\") ->
            {blocks, [trimmed | current]}

          # Skip other lines.
          current == [] ->
            {blocks, current}

          # Non-assignment, non-state line after trace starts — end of trace.
          true ->
            if current != [] do
              {[Enum.reverse(current) | blocks], []}
            else
              {blocks, current}
            end
        end
      end)

    blocks = if current != [], do: [Enum.reverse(current) | blocks], else: blocks
    Enum.reverse(blocks)
  end

  defp parse_state_block([header | rest]) do
    {number, action} = parse_state_header(header)
    assignments = parse_assignments(rest)

    %{number: number, action: action, assignments: assignments}
  end

  defp parse_state_block([]) do
    %{number: 0, action: nil, assignments: %{}}
  end

  defp parse_state_header(header) do
    cond do
      # "State N: <Initial predicate>"
      result = Regex.run(~r/^State (\d+): <Initial predicate>/, header) ->
        [_, n] = result
        {String.to_integer(n), nil}

      # "State N: <ActionName line X, col Y ...>"
      result = Regex.run(~r/^State (\d+): <(\w+)/, header) ->
        [_, n, action] = result
        {String.to_integer(n), action}

      # "State N: <ActionName>"
      result = Regex.run(~r/^State (\d+): <(.+?)>/, header) ->
        [_, n, action] = result
        {String.to_integer(n), action}

      # "Back to state N: <ActionName ...>"
      result = Regex.run(~r/^Back to state (\d+): <(\w+)/, header) ->
        [_, n, action] = result
        {String.to_integer(n), action}

      true ->
        {0, nil}
    end
  end

  defp parse_assignments(lines) do
    lines
    |> Enum.reduce(%{}, fn line, acc ->
      trimmed = String.trim(line)

      case Regex.run(~r|^/\\\s+(\w+)\s*=\s*(.+)$|, trimmed) do
        [_, var, value] -> Map.put(acc, var, String.trim(value))
        _ -> acc
      end
    end)
  end

  # -- Stats parsing --

  defp parse_stats(lines) do
    generated = extract_stat(lines, ~r/(\d[\d,]*)\s+states? generated/)
    distinct = extract_stat(lines, ~r/(\d[\d,]*)\s+distinct states? found/)
    depth = extract_stat(lines, ~r/depth of the complete state graph search is (\d+)/)

    %{
      states_generated: generated || 0,
      distinct_states: distinct || 0,
      depth: depth
    }
  end

  defp extract_stat(lines, regex) do
    lines
    |> Enum.find_value(fn line ->
      case Regex.run(regex, line) do
        [_, value] ->
          value
          |> String.replace(",", "")
          |> String.to_integer()

        _ ->
          nil
      end
    end)
  end
end
