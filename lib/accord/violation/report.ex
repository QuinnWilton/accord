defmodule Accord.Violation.Report do
  @moduledoc """
  Formats protocol violations as pentiment diagnostics.

  Converts `Accord.Violation` structs into rich, source-annotated error
  messages using pentiment. When a compiled protocol is available, the
  report points to the relevant transition in the protocol source file.

  ## With compiled protocol

      formatted = Accord.Violation.Report.format(violation, compiled)

  ## Without compiled protocol (fallback)

      formatted = Accord.Violation.Report.format(violation)

  ## In property tests

      report = Accord.Violation.Report.failure_report(history, compiled)
  """

  alias Accord.IR.Type
  alias Accord.Monitor.{Compiled, TransitionTable}
  alias Accord.Violation
  alias Pentiment.{Label, Report, Source}

  # -- Public API --

  @doc """
  Formats a violation with source spans from the compiled protocol.

  Looks up the transition in the protocol's transition table to find the
  source span, then renders a full pentiment diagnostic with source context.
  """
  @spec format(Violation.t(), Compiled.t()) :: String.t()
  def format(%Violation{} = violation, %Compiled{} = compiled) do
    report =
      build_report(violation)
      |> add_source_label(violation, compiled)

    case compiled.ir.source_file do
      path when is_binary(path) ->
        if File.exists?(path) do
          source = Source.from_file(path)
          Pentiment.format(report, source)
        else
          Pentiment.format(report, nil)
        end

      nil ->
        Pentiment.format(report, nil)
    end
  end

  @doc """
  Formats a violation without source spans.

  Renders the diagnostic message with notes and help, but without
  source code context.
  """
  @spec format(Violation.t()) :: String.t()
  def format(%Violation{} = violation) do
    report = build_report(violation)
    Pentiment.format(report, nil)
  end

  @doc """
  Builds a failure report string for a property test.

  Extracts the last history entry and, if it contains an accord violation,
  formats it as a pentiment diagnostic. Also builds a simplified step
  summary showing the protocol state progression.

  Falls back to `inspect` for non-violation failures.
  """
  @spec failure_report(list(), list(), Compiled.t(), [Violation.t()]) :: String.t()
  def failure_report(history, commands, compiled, property_violations \\ [])

  def failure_report(history, commands, %Compiled{} = compiled, property_violations) do
    output = format_failure(history, commands, compiled)

    case property_violations do
      [] ->
        output

      violations ->
        formatted =
          Enum.map_join(violations, "\n", fn v -> "  " <> format(v, compiled) end)

        output <> "\n\nProperty violations detected during run:\n" <> formatted
    end
  end

  # -- Report Building --

  defp build_report(%Violation{kind: :invalid_reply} = v) do
    Report.error("server returned invalid reply")
    |> Report.with_note("sent #{inspect(v.message)}, got #{inspect(v.reply)}")
    |> add_valid_replies_help(v.context)
  end

  defp build_report(%Violation{kind: :invalid_message} = v) do
    Report.error("message not valid in state :#{v.state}")
    |> Report.with_note("sent #{inspect(v.message)} in state :#{v.state}")
    |> add_valid_messages_help(v.expected)
  end

  defp build_report(%Violation{kind: :guard_failed} = v) do
    Report.error("guard rejected message")
    |> Report.with_note("guard rejected #{inspect(v.message)} in state :#{v.state}")
  end

  defp build_report(%Violation{kind: :argument_type} = v) do
    pos = v.context[:position]
    actual = v.context[:actual_value]
    expected = v.context[:expected_type]

    Report.error("argument type mismatch")
    |> Report.with_note("argument #{pos} has type #{type_of(actual)}, value: #{inspect(actual)}")
    |> Report.with_help("expected #{Type.to_string(expected)}")
  end

  defp build_report(%Violation{kind: :session_ended} = v) do
    Report.error("session has ended")
    |> Report.with_note("sent #{inspect(v.message)} after terminal state :#{v.state}")
  end

  defp build_report(%Violation{kind: :timeout} = v) do
    Report.error("server timed out")
    |> Report.with_note("sent #{inspect(v.message)}, timed out after #{v.context[:timeout_ms]}ms")
  end

  defp build_report(%Violation{kind: :invariant_violated} = v) do
    Report.error("invariant violated")
    |> Report.with_note("property :#{v.context[:property]} failed")
    |> Report.with_note("tracks: #{inspect(v.context[:tracks], pretty: true)}")
  end

  defp build_report(%Violation{kind: :action_violated} = v) do
    Report.error("action property violated")
    |> Report.with_note("property :#{v.context[:property]} failed")
    |> Report.with_note("old: #{inspect(v.context[:old_tracks], pretty: true)}")
    |> Report.with_note("new: #{inspect(v.context[:new_tracks], pretty: true)}")
  end

  defp build_report(%Violation{kind: :liveness_violated} = v) do
    Report.error("liveness property violated")
    |> Report.with_note("property :#{v.context[:property]} failed")
  end

  defp build_report(%Violation{} = v) do
    Report.error("protocol violation: #{v.kind}")
    |> Report.with_note("state: :#{v.state}, message: #{inspect(v.message)}")
  end

  # -- Source Labels --

  defp add_source_label(report, violation, compiled) do
    case compiled.ir.source_file do
      nil ->
        report

      path ->
        report = Report.with_source(report, path)
        span = violation.span || lookup_transition_span(violation, compiled)

        case span do
          nil -> report
          span -> Report.with_label(report, Label.primary(span, label_message(violation.kind)))
        end
    end
  end

  defp lookup_transition_span(%Violation{} = violation, %Compiled{} = compiled) do
    case TransitionTable.lookup(compiled.transition_table, violation.state, violation.message) do
      {:ok, transition} -> transition.span
      :error -> nil
    end
  end

  defp label_message(:invalid_reply), do: "transition defined here"
  defp label_message(:argument_type), do: "type constraint defined here"
  defp label_message(:guard_failed), do: "guarded transition defined here"
  defp label_message(:invariant_violated), do: "property defined here"
  defp label_message(:action_violated), do: "property defined here"
  defp label_message(:liveness_violated), do: "property defined here"
  defp label_message(_), do: "transition defined here"

  # -- Help Builders --

  defp add_valid_replies_help(report, %{valid_replies: replies}) when is_list(replies) do
    formatted = Enum.map_join(replies, " | ", &Type.to_string/1)
    Report.with_help(report, "expected #{formatted}")
  end

  defp add_valid_replies_help(report, _), do: report

  defp add_valid_messages_help(report, expected) when is_list(expected) and expected != [] do
    formatted = Enum.map_join(expected, ", ", &inspect/1)
    Report.with_help(report, "valid messages: #{formatted}")
  end

  defp add_valid_messages_help(report, _), do: report

  # -- Failure Formatting --

  defp format_failure(history, commands, compiled) do
    steps = format_step_summary(history, commands)

    diagnostic =
      case List.last(history) do
        {_model_state, {:accord_violation, %Violation{} = violation}} ->
          format(violation, compiled)

        {_model_state, result} ->
          "Failing result: #{inspect(result, pretty: true)}"

        nil ->
          "(empty history)"
      end

    "\n#{steps}\n#{diagnostic}"
  end

  # -- Step Summary --

  defp format_step_summary(history, commands) do
    # Strip the {:init, _} entry from the command list.
    cmds = Enum.reject(commands, &match?({:init, _}, &1))
    count = length(history)
    header = "--- Steps (#{count}) ---\n"

    steps =
      history
      |> Enum.zip(cmds)
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {{{model, result}, cmd}, idx} ->
        state = if is_map(model), do: Map.get(model, :protocol_state, "?"), else: "?"
        call = format_command(cmd)
        "  #{idx}. :#{state} #{call} → #{format_result_brief(result)}"
      end)

    header <> steps
  end

  defp format_command({:set, _var, {:call, _mod, fun, args}}) do
    formatted_args = Enum.map_join(args, ", ", &inspect(&1, limit: 3))
    "#{fun}(#{formatted_args})"
  end

  defp format_command(_), do: "?"

  defp format_result_brief({:accord_violation, %Violation{} = v}) do
    "VIOLATION (#{v.blame}: #{v.kind})"
  end

  defp format_result_brief(result) do
    inspect(result, limit: 5)
  end

  # -- Type Inspection --

  defp type_of(value) when is_boolean(value), do: "boolean"
  defp type_of(value) when is_integer(value), do: "integer"
  defp type_of(value) when is_float(value), do: "float"
  defp type_of(value) when is_binary(value), do: "binary"
  defp type_of(value) when is_atom(value), do: "atom"
  defp type_of(value) when is_list(value), do: "list"
  defp type_of(value) when is_map(value), do: "map"
  defp type_of(value) when is_tuple(value), do: "tuple"
  defp type_of(_), do: "term"
end
