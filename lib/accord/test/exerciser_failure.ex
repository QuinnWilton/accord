defmodule Accord.Test.ExerciserFailure do
  @moduledoc """
  Exception raised when the protocol exerciser detects a mismatch
  between expected and actual outcomes.

  Contains the step trace leading up to the failure. The failing
  step's violation is formatted as a pentiment diagnostic with
  source spans when a compiled protocol is available.
  """

  alias Accord.Violation

  defexception [:steps, :property_violations, :compiled]

  @type outcome :: :ok | {:violation, atom(), atom()} | :session_ended | :skipped
  @type step :: %{
          command: term(),
          state: atom(),
          tracks: map(),
          transition: term(),
          message: term(),
          expected: outcome(),
          actual: term(),
          passed: boolean()
        }

  @type t :: %__MODULE__{
          steps: [step()],
          property_violations: [Violation.t()],
          compiled: Accord.Monitor.Compiled.t() | nil
        }

  @impl true
  def message(%__MODULE__{} = e) do
    step_count = length(e.steps)
    failing = Enum.find(e.steps, &(not &1.passed))

    header =
      if e.compiled do
        "Protocol exerciser failure for #{inspect(e.compiled.ir.name)}"
      else
        "Protocol exerciser failure"
      end

    steps_summary = format_steps(e.steps)

    failure_detail =
      if failing do
        diagnostic = format_failing_step(failing, e.compiled)

        """

        Failing step:
          command:  #{inspect(failing.command)}
          state:    :#{failing.state}
          tracks:   #{inspect(failing.tracks, pretty: true, limit: 10)}
          message:  #{inspect(failing.message, limit: 5)}
          expected: #{format_outcome(failing.expected)}

        #{diagnostic}
        """
      else
        ""
      end

    prop_detail = format_property_violations(e.property_violations, e.compiled)

    """
    #{header}
    --- Steps (#{step_count}) ---
    #{steps_summary}#{failure_detail}#{prop_detail}
    """
  end

  # -- Step formatting --

  defp format_steps(steps) do
    steps
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {step, idx} ->
      status = if step.passed, do: "ok", else: "FAIL"
      msg_str = inspect(step.message, limit: 5)
      "  #{idx}. :#{step.state} #{msg_str} -> #{format_outcome(step.expected)} [#{status}]"
    end)
  end

  # -- Failing step diagnostic --

  defp format_failing_step(%{actual: {:accord_violation, %Violation{} = v}}, %{} = compiled) do
    Violation.Report.format(v, compiled, strict: true)
  end

  defp format_failing_step(%{actual: {:accord_violation, %Violation{} = v}}, _compiled) do
    Violation.Report.format(v)
  end

  defp format_failing_step(%{actual: actual, expected: expected}, _compiled) do
    "expected: #{format_outcome(expected)}\n     got: #{inspect(actual, pretty: true, limit: 10)}"
  end

  # -- Property violation formatting --

  defp format_property_violations([], _compiled), do: ""

  defp format_property_violations(violations, %{} = compiled) do
    formatted =
      Enum.map_join(violations, "\n\n", fn v ->
        Violation.Report.format(v, compiled, strict: true)
      end)

    "\n\nProperty violations detected during run:\n" <> formatted
  end

  defp format_property_violations(violations, _compiled) do
    formatted =
      Enum.map_join(violations, "\n\n", fn v ->
        Violation.Report.format(v)
      end)

    "\n\nProperty violations detected during run:\n" <> formatted
  end

  # -- Outcome labels --

  defp format_outcome(:ok), do: "ok"
  defp format_outcome(:session_ended), do: "session_ended"
  defp format_outcome(:skipped), do: "skipped"
  defp format_outcome(:ok_or_violation), do: "ok (or violation)"
  defp format_outcome({:violation, blame, kind}), do: "#{blame}:#{kind}"
  defp format_outcome(other), do: inspect(other)
end
