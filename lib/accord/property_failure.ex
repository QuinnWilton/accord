defmodule Accord.PropertyFailure do
  @moduledoc """
  Exception raised when a property test detects protocol violations.

  Wraps the command history, compiled protocol, and collected violations.
  The diagnostic report is formatted lazily via `Exception.message/1`.
  """

  defexception [:history, :compiled, :violations]

  @type t :: %__MODULE__{
          history: list(),
          compiled: Accord.Monitor.Compiled.t(),
          violations: [Accord.Violation.t()]
        }

  @impl true
  def message(%__MODULE__{} = e) do
    Accord.Violation.Report.failure_report(e.history, e.compiled, e.violations)
  end
end
