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
          kind: :invariant | :deadlock | :temporal,
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

    cond do
      success?(lines) ->
        {:ok, stats}

      invariant_violation?(lines) ->
        property = extract_invariant_name(lines)
        trace = parse_trace(lines)
        {:error, %{kind: :invariant, property: property, trace: trace}, stats}

      deadlock?(lines) ->
        trace = parse_trace(lines)
        {:error, %{kind: :deadlock, property: nil, trace: trace}, stats}

      temporal_violation?(lines) ->
        trace = parse_trace(lines)
        {:error, %{kind: :temporal, property: nil, trace: trace}, stats}

      true ->
        # Unknown output — treat as error with empty trace.
        {:error, %{kind: :invariant, property: nil, trace: []}, stats}
    end
  end

  # -- Detection --

  defp success?(lines) do
    Enum.any?(lines, &String.contains?(&1, "Model checking completed. No error has been found."))
  end

  defp invariant_violation?(lines) do
    Enum.any?(lines, &Regex.match?(~r/^Error: Invariant .+ is violated/, &1))
  end

  defp deadlock?(lines) do
    Enum.any?(lines, &String.contains?(&1, "Error: Deadlock reached."))
  end

  defp temporal_violation?(lines) do
    Enum.any?(lines, &String.contains?(&1, "Error: Temporal properties were violated."))
  end

  # -- Invariant name extraction --

  defp extract_invariant_name(lines) do
    lines
    |> Enum.find_value(fn line ->
      case Regex.run(~r/^Error: Invariant (.+) is violated/, line) do
        [_, name] -> name
        _ -> nil
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
  defp split_into_state_blocks(lines) do
    {blocks, current} =
      Enum.reduce(lines, {[], []}, fn line, {blocks, current} ->
        trimmed = String.trim(line)

        cond do
          Regex.match?(~r/^State \d+:/, trimmed) ->
            if current == [] do
              {blocks, [trimmed]}
            else
              {blocks ++ [current], [trimmed]}
            end

          Regex.match?(~r/^Back to state \d+:/, trimmed) ->
            if current == [] do
              {blocks, [trimmed]}
            else
              {blocks ++ [current], [trimmed]}
            end

          # Stop at non-trace lines (stats, empty lines after trace).
          trimmed == "" and current != [] ->
            {blocks ++ [current], []}

          # Assignment lines or continuation.
          String.starts_with?(trimmed, "/\\") ->
            {blocks, current ++ [trimmed]}

          # Skip other lines.
          current == [] ->
            {blocks, current}

          # Non-assignment, non-state line after trace starts — end of trace.
          true ->
            if current != [] do
              {blocks ++ [current], []}
            else
              {blocks, current}
            end
        end
      end)

    if current != [], do: blocks ++ [current], else: blocks
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
