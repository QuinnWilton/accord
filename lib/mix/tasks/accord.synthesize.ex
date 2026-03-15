defmodule Mix.Tasks.Accord.Synthesize do
  @moduledoc """
  Synthesizes an Accord protocol from an OTP module using LLM-assisted analysis.

  Extracts structural facts from the target module, builds a prompt with
  the Accord DSL reference and worked examples, sends it to the `claude` CLI,
  and validates the result through Accord's compilation pipeline.

  ## Usage

      mix accord.synthesize MyApp.Counter              # from a compiled module
      mix accord.synthesize MyApp.Counter --check      # also run TLC after synthesis
      mix accord.synthesize MyApp.Counter --dry-run    # print prompt, don't invoke LLM
      mix accord.synthesize --file path/to/server.ex   # from a source file (no compilation)
      mix accord.synthesize --all                      # all GenServer/gen_statem modules
      mix accord.synthesize MyApp.Counter --output lib/my_app/  # custom output

  ## Output

  Generated protocols are written to `protocols/` by default (add to `.gitignore`).
  Use `--output` to write to a custom directory (e.g., `lib/` when confident
  in the result).

  ## Requirements

  The `claude` CLI must be installed and available in PATH.
  """

  use Mix.Task

  @shortdoc "Synthesize an Accord protocol from an OTP module"

  @switches [
    check: :boolean,
    dry_run: :boolean,
    all: :boolean,
    output: :string,
    file: :string
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("compile", [])

    {opts, modules, _} = OptionParser.parse(args, strict: @switches)

    output_dir = Keyword.get(opts, :output, "protocols")

    synth_opts = [
      output_dir: output_dir,
      check: Keyword.get(opts, :check, false),
      dry_run: Keyword.get(opts, :dry_run, false)
    ]

    results =
      case Keyword.get(opts, :file) do
        nil ->
          # Module-based synthesis (requires compiled modules).
          modules = resolve_modules(modules, opts)

          if modules == [] do
            Mix.shell().error("No modules specified. Usage: mix accord.synthesize MyApp.Counter")

            exit({:shutdown, 1})
          end

          Enum.map(modules, fn mod ->
            Mix.shell().info("Synthesizing protocol for #{inspect(mod)}...")
            {mod, Accord.Synthesize.run(mod, synth_opts)}
          end)

        file_path ->
          # File-based synthesis (no compilation needed).
          unless File.exists?(file_path) do
            Mix.raise("File not found: #{file_path}")
          end

          Mix.shell().info("Synthesizing protocol from #{file_path}...")
          [{file_path, Accord.Synthesize.run_from_file(file_path, synth_opts)}]
      end

    report_results(results, opts)
  end

  # -- Module Resolution --

  defp resolve_modules([], opts) do
    if Keyword.get(opts, :all, false) do
      discover_otp_modules()
    else
      []
    end
  end

  defp resolve_modules(names, _opts) do
    Enum.map(names, fn name ->
      # Developer-provided CLI argument, not untrusted input.
      mod = Module.concat([String.to_atom(name)])

      unless Code.ensure_loaded?(mod) do
        Mix.raise("Unknown module: #{inspect(mod)}. Is the module compiled?")
      end

      mod
    end)
  end

  defp discover_otp_modules do
    Mix.Project.compile_path()
    |> Path.join("*.beam")
    |> Path.wildcard()
    |> Enum.flat_map(fn beam_path ->
      module =
        beam_path
        |> Path.basename(".beam")
        # Beam file names correspond to already-loaded atoms.
        |> String.to_atom()

      if Code.ensure_loaded?(module) and otp_module?(module) do
        [module]
      else
        []
      end
    end)
  rescue
    _ -> []
  end

  defp otp_module?(mod) do
    behaviours =
      (mod.module_info(:attributes)[:behaviour] || []) ++
        (mod.module_info(:attributes)[:behavior] || [])

    Enum.any?(behaviours, &(&1 in [GenServer, :gen_server, :gen_statem]))
  rescue
    _ -> false
  end

  # -- Result Reporting --

  defp report_results(results, opts) do
    dry_run? = Keyword.get(opts, :dry_run, false)

    if dry_run? do
      for {_mod, {:ok, prompt}} <- results do
        Mix.shell().info(prompt)
      end
    else
      {successes, failures} =
        Enum.split_with(results, fn
          {_mod, {:ok, _}} -> true
          _ -> false
        end)

      for {mod, {:ok, path}} <- successes do
        Mix.shell().info("#{IO.ANSI.green()}✓#{IO.ANSI.reset()} #{inspect(mod)} → #{path}")
      end

      for {mod, {:error, reason}} <- failures do
        message = format_error(reason)

        Mix.shell().info("#{IO.ANSI.red()}✗#{IO.ANSI.reset()} #{inspect(mod)} — #{message}")
      end

      if failures != [] do
        Mix.shell().info(
          "\n#{IO.ANSI.red()}#{length(failures)} module(s) failed.#{IO.ANSI.reset()}"
        )

        exit({:shutdown, 1})
      else
        count = length(successes)

        Mix.shell().info(
          "\n#{IO.ANSI.green()}#{count} protocol(s) synthesized.#{IO.ANSI.reset()}"
        )
      end
    end
  end

  defp format_error(:not_loaded), do: "module not loaded"
  defp format_error(:no_source), do: "source file not found"
  defp format_error(:validation_failed), do: "validation failed after max iterations"

  defp format_error({:not_found, msg}), do: msg

  defp format_error({:exit, code, output}),
    do: "claude exited with code #{code}: #{String.slice(output, 0, 200)}"

  defp format_error(other), do: inspect(other)
end
