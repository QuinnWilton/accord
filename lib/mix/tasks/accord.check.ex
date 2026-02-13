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

  alias Accord.TLA.TLCParser

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
        Enum.map(modules, &Module.concat([String.to_atom(&1)]))
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

  defp report_failure(mod, {:error, %{kind: kind, property: property, trace: trace}, stats}) do
    label =
      case kind do
        :invariant -> "invariant #{property || "unknown"} violated"
        :action_property -> "action property #{property || "unknown"} violated"
        :deadlock -> "deadlock reached"
        :temporal -> "temporal property violated"
      end

    Mix.shell().info(
      "#{IO.ANSI.red()}✗#{IO.ANSI.reset()} #{inspect(mod)} — #{label} " <>
        "(#{stats.distinct_states} states explored)"
    )

    # Render counterexample trace.
    if trace != [] do
      Mix.shell().info("\n  Counterexample trace:\n")

      for entry <- trace do
        action_label =
          case entry.action do
            nil -> "Initial"
            name -> name
          end

        Mix.shell().info("  State #{entry.number}: #{action_label}")

        # Map action name to source span if available.
        if entry.action && function_exported?(mod, :__tla_span__, 1) do
          case mod.__tla_span__(entry.action) do
            %Pentiment.Span.Position{} = span ->
              ir = mod.__ir__()
              file = ir.source_file || "unknown"

              Mix.shell().info(
                "    #{IO.ANSI.cyan()}→ #{file}:#{span.start_line}#{IO.ANSI.reset()}"
              )

            _ ->
              :ok
          end
        end

        for {var, val} <- Enum.sort(entry.assignments) do
          # Map variable name to source span.
          span_note =
            if function_exported?(mod, :__tla_span__, 1) do
              case mod.__tla_span__(var) do
                %Pentiment.Span.Position{} = span ->
                  " (#{Path.basename(mod.__ir__().source_file || "")}:#{span.start_line})"

                _ ->
                  ""
              end
            else
              ""
            end

          Mix.shell().info("    #{var} = #{val}#{span_note}")
        end

        Mix.shell().info("")
      end
    end

    # Map violated property to source span.
    if property && function_exported?(mod, :__tla_span__, 1) do
      case mod.__tla_span__(property) do
        %Pentiment.Span.Position{} = span ->
          ir = mod.__ir__()
          file = ir.source_file || "unknown"

          Mix.shell().info(
            "  Property defined at: #{IO.ANSI.cyan()}#{file}:#{span.start_line}#{IO.ANSI.reset()}\n"
          )

        _ ->
          :ok
      end
    end
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
end
