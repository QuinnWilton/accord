defmodule Mix.Tasks.Accord.Check do
  @moduledoc """
  Runs TLC model checking against generated TLA+ specs.

  Discovers protocol modules (those defining `__tla_span__/1`), locates
  their generated `.tla` and `.cfg` files in `_build/accord/`, shells out
  to TLC, parses results, and maps counterexamples back to Elixir source
  using `__tla_span__/1`.

  ## Usage

      mix accord.check                          # check all protocols
      mix accord.check Lock.Protocol            # check a specific protocol
      mix accord.check --workers 4              # TLC parallelism

  ## Requirements

  TLC must be available. The task looks for `tla2tools.jar` at:

  1. `TLA2TOOLS_JAR` environment variable
  2. `~/.tla/tla2tools.jar`
  3. `tla2tools.jar` in the current directory

  Install TLC from https://github.com/tlaplus/tlaplus/releases
  """

  use Mix.Task

  alias Accord.TLA.{TLCParser, ViolationReport}

  @shortdoc "Run TLC model checking on Accord protocols"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("compile", [])

    {opts, modules, _} =
      OptionParser.parse(args, strict: [workers: :integer])

    workers = Keyword.get(opts, :workers)

    protocols =
      if modules == [] do
        discover_protocols()
      else
        Enum.map(modules, fn name ->
          # Safe: developer-provided CLI argument, not untrusted input.
          mod = Module.concat([String.to_atom(name)])

          unless Code.ensure_loaded?(mod) do
            Mix.raise("Unknown module: #{inspect(mod)}. Is the module compiled?")
          end

          mod
        end)
      end

    if protocols == [] do
      Mix.shell().info("No Accord protocols found.")
      :ok
    else
      Mix.shell().info("Checking #{length(protocols)} protocol(s)...\n")

      results =
        Enum.map(protocols, fn mod ->
          {mod, check_protocol(mod, workers)}
        end)

      report_results(results)
    end
  end

  # -- Protocol Discovery --

  defp discover_protocols do
    Mix.Project.compile_path()
    |> Path.join("*.beam")
    |> Path.wildcard()
    |> Enum.flat_map(fn beam_path ->
      module =
        beam_path
        |> Path.basename(".beam")
        # Safe: beam file names correspond to already-loaded atoms.
        |> String.to_atom()

      if Code.ensure_loaded?(module) and function_exported?(module, :__tla_span__, 1) do
        [module]
      else
        []
      end
    end)
  rescue
    _ -> []
  end

  # -- Protocol Checking --

  defp check_protocol(mod, workers) do
    with :ok <- ensure_loaded(mod),
         :ok <- ensure_protocol(mod),
         {tla_path, cfg_path} <- tla_paths(mod),
         :ok <- ensure_file(tla_path, :tla_not_found),
         :ok <- ensure_file(cfg_path, :cfg_not_found),
         {:ok, tlc_jar} <- require_tlc() do
      run_tlc(mod, tla_path, cfg_path, tlc_jar, workers)
    end
  end

  defp ensure_loaded(mod) do
    if Code.ensure_loaded?(mod), do: :ok, else: {:error, :module_not_found}
  end

  defp ensure_protocol(mod) do
    if function_exported?(mod, :__tla_span__, 1), do: :ok, else: {:error, :not_a_protocol}
  end

  defp ensure_file(path, error_tag) do
    if File.exists?(path), do: :ok, else: {:error, error_tag}
  end

  defp require_tlc do
    case find_tlc() do
      nil -> {:error, :tlc_not_found}
      jar -> {:ok, jar}
    end
  end

  defp tla_paths(mod) do
    parts = Module.split(mod)
    dir_parts = parts |> Enum.slice(0..-2//1) |> Enum.map(&Macro.underscore/1)

    base_dir = Path.join([Mix.Project.build_path(), "accord" | dir_parts])
    base_name = List.last(parts)

    {
      Path.join(base_dir, "#{base_name}.tla"),
      Path.join(base_dir, "#{base_name}.cfg")
    }
  end

  defp find_tlc do
    cond do
      env = System.get_env("TLA2TOOLS_JAR") ->
        if File.exists?(env), do: env

      File.exists?(Path.expand("~/.tla/tla2tools.jar")) ->
        Path.expand("~/.tla/tla2tools.jar")

      File.exists?("tla2tools.jar") ->
        Path.expand("tla2tools.jar")

      true ->
        nil
    end
  end

  defp run_tlc(_mod, tla_path, cfg_path, tlc_jar, workers) do
    tla_dir = Path.dirname(tla_path)
    tla_file = Path.basename(tla_path)

    args = [
      "-jar",
      tlc_jar,
      "-config",
      Path.basename(cfg_path),
      "-deadlock",
      tla_file
    ]

    args = if workers, do: args ++ ["-workers", Integer.to_string(workers)], else: args

    case System.cmd("java", args, cd: tla_dir, stderr_to_stdout: true) do
      {output, 0} ->
        TLCParser.parse(output)

      {output, _exit_code} ->
        # TLC returns non-zero on violations.
        TLCParser.parse(output)
    end
  rescue
    e in ErlangError ->
      {:error, :java_not_found, inspect(e)}
  end

  # -- Result Reporting --

  defp report_results(results) do
    {successes, failures} =
      Enum.split_with(results, fn
        {_mod, {:ok, _}} -> true
        _ -> false
      end)

    # Report successes.
    for {mod, {:ok, stats}} <- successes do
      Mix.shell().info(
        "#{IO.ANSI.green()}✓#{IO.ANSI.reset()} #{inspect(mod)} — " <>
          "#{stats.distinct_states} states explored" <>
          if(stats.depth, do: ", depth #{stats.depth}", else: "")
      )
    end

    # Report failures.
    for {mod, result} <- failures do
      report_failure(mod, result)
    end

    if failures != [] do
      Mix.shell().info(
        "\n#{IO.ANSI.red()}#{length(failures)} protocol(s) failed.#{IO.ANSI.reset()}"
      )

      # Exit with failure status for CI.
      System.at_exit(fn _ -> :ok end)
      exit({:shutdown, 1})
    else
      Mix.shell().info(
        "\n#{IO.ANSI.green()}All #{length(successes)} protocol(s) passed.#{IO.ANSI.reset()}"
      )
    end
  end

  defp report_failure(mod, {:error, %{kind: _, trace: _} = violation, stats}) do
    label = violation_label(violation)

    Mix.shell().info(
      "#{IO.ANSI.red()}✗#{IO.ANSI.reset()} #{inspect(mod)} — #{label} " <>
        "(#{stats.distinct_states} states explored)"
    )

    formatted = ViolationReport.format(violation, mod)
    Mix.shell().info("\n" <> formatted)
  end

  defp report_failure(mod, {:error, reason}) do
    message =
      case reason do
        :module_not_found -> "module not found"
        :not_a_protocol -> "not an Accord protocol"
        :tla_not_found -> ".tla file not found (run `mix compile` first)"
        :cfg_not_found -> ".cfg file not found (run `mix compile` first)"
        :tlc_not_found -> "TLC not found (set TLA2TOOLS_JAR or install to ~/.tla/)"
        :java_not_found -> "Java not found (TLC requires a JVM)"
        other -> inspect(other)
      end

    Mix.shell().info("#{IO.ANSI.red()}✗#{IO.ANSI.reset()} #{inspect(mod)} — #{message}")
  end

  defp report_failure(mod, {:error, reason, detail}) do
    Mix.shell().info("#{IO.ANSI.red()}✗#{IO.ANSI.reset()} #{inspect(mod)} — #{reason}: #{detail}")
  end

  defp violation_label(%{kind: :invariant, property: property}) do
    "invariant #{property || "unknown"} violated"
  end

  defp violation_label(%{kind: :action_property, property: property}) do
    "action property #{property || "unknown"} violated"
  end

  defp violation_label(%{kind: :deadlock}), do: "deadlock reached"
  defp violation_label(%{kind: :temporal}), do: "temporal property violated"
  defp violation_label(%{kind: :error}), do: "TLC error"
end
