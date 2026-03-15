defmodule Accord.Synthesize.CLI do
  @moduledoc """
  Shells out to the `claude` CLI for LLM-powered protocol synthesis.

  All LLM interaction is contained within the `Accord.Synthesize` namespace.
  This module is the single point of contact with the external LLM process.

  Uses `claude -p` in non-interactive mode with plain text output. The prompt
  is passed as a CLI argument, which limits prompt size to the OS argument
  length limit (~256KB on macOS). For the expected prompt sizes in protocol
  synthesis (DSL reference + examples + single module source), this is
  well within limits.
  """

  @type error ::
          {:exit, non_neg_integer(), String.t()}
          | {:not_found, String.t()}

  @doc """
  Send a prompt to the `claude` CLI and return the response text.

  Returns `{:ok, response}` on success or `{:error, reason}` on failure.
  """
  @spec complete(String.t()) :: {:ok, String.t()} | {:error, error()}
  def complete(prompt) do
    case System.find_executable("claude") do
      nil ->
        {:error, {:not_found, "claude CLI not found in PATH"}}

      executable ->
        run(executable, prompt)
    end
  end

  defp run(executable, prompt) do
    case System.cmd(executable, ["-p", prompt, "--output-format", "text"], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, {:exit, code, output}}
    end
  rescue
    e in ErlangError ->
      {:error, {:exit, 1, "failed to execute claude: #{inspect(e)}"}}
  end
end
