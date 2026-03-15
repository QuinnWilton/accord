defmodule Accord.Synthesize.Refinement do
  @moduledoc """
  Iterative refinement loops for synthesized protocols.

  Implements two feedback channels following the CodeLogician architecture:

  - **Channel 1 (validation)**: Compile the protocol through Accord's 7
    validation passes. Feed structural/type/determinism errors back to the
    LLM for correction. Fast (milliseconds), converges in 1-3 iterations.

  - **Channel 2 (TLC model checking)**: Run TLC against the compiled TLA+
    spec. Feed counterexample traces back to the LLM for protocol refinement.
    Slower (seconds-minutes), catches semantic errors that structural
    validation misses.

  Both channels use bounded iteration with configurable maximums.
  """

  alias Accord.Synthesize.{CLI, Prompt}
  alias Accord.Synthesize.Extractor

  require Logger

  @type facts :: Extractor.facts()

  @doc """
  Run the validation refinement loop (Channel 1).

  Attempts to compile the protocol source through Accord's validation
  pipeline. On failure, feeds the error diagnostics back to the LLM and
  retries up to `max_iterations` times.

  Returns `{:ok, protocol_source}` when validation passes, or
  `{:error, reason, last_source}` when iterations are exhausted.
  """
  @spec validation_loop(String.t(), facts(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, atom(), String.t()}
  def validation_loop(protocol_source, facts, source, opts \\ []) do
    max = Keyword.get(opts, :max_iterations, 5)
    do_validation(protocol_source, facts, source, max, 1)
  end

  @doc """
  Run the TLC model checking refinement loop (Channel 2).

  Requires a compiled protocol module (validation must have passed).
  Runs TLC against the generated TLA+ spec and feeds counterexamples
  back to the LLM for refinement.

  The `output_path` is the file where the protocol source lives; it will
  be rewritten on each refinement iteration.
  """
  @spec tlc_loop(String.t(), String.t(), facts(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, atom(), String.t()}
  def tlc_loop(protocol_source, output_path, facts, source, opts \\ []) do
    max = Keyword.get(opts, :max_iterations, 3)
    do_tlc(protocol_source, output_path, facts, source, max, 1)
  end

  # -- Channel 1: Validation Loop --

  defp do_validation(protocol_source, _facts, _source, max, iteration) when iteration > max do
    {:error, :max_iterations, protocol_source}
  end

  defp do_validation(protocol_source, facts, source, max, iteration) do
    case try_compile(protocol_source) do
      :ok ->
        log_iteration(:validation, iteration, :ok)
        {:ok, protocol_source}

      {:error, errors} ->
        log_iteration(:validation, iteration, :error)

        prompt = Prompt.build_validation_refinement(protocol_source, errors, facts, source)

        case CLI.complete(prompt) do
          {:ok, response} ->
            refined = Prompt.extract_code_block(response)
            do_validation(refined, facts, source, max, iteration + 1)

          {:error, reason} ->
            {:error, :llm_error, "LLM refinement failed: #{inspect(reason)}"}
        end
    end
  end

  # -- Channel 2: TLC Loop --

  defp do_tlc(protocol_source, _output_path, _facts, _source, max, iteration)
       when iteration > max do
    {:error, :max_iterations, protocol_source}
  end

  defp do_tlc(protocol_source, output_path, facts, source, max, iteration) do
    # Recompile the protocol to generate fresh TLA+ files.
    case try_compile(protocol_source) do
      {:error, errors} ->
        # Protocol no longer compiles — bail.
        {:error, :compile_error, errors}

      :ok ->
        case run_tlc(protocol_source) do
          {:ok, _stats} ->
            log_iteration(:tlc, iteration, :ok)
            {:ok, protocol_source}

          {:error, violation_report} ->
            log_iteration(:tlc, iteration, :error)

            prompt =
              Prompt.build_tlc_refinement(protocol_source, violation_report, facts, source)

            case CLI.complete(prompt) do
              {:ok, response} ->
                refined = Prompt.extract_code_block(response)

                # Write the refined source so the next iteration can compile it.
                File.write!(output_path, refined)
                do_tlc(refined, output_path, facts, source, max, iteration + 1)

              {:error, reason} ->
                {:error, :llm_error, "LLM refinement failed: #{inspect(reason)}"}
            end
        end
    end
  end

  # -- Compilation --

  # Attempt to compile a protocol source string through Accord's validation
  # pipeline. Uses Code.compile_string/2 which triggers @before_compile,
  # running all 7 validation passes.
  @spec try_compile(String.t()) :: :ok | {:error, String.t()}
  defp try_compile(protocol_source) do
    # Suppress module redefinition warnings during iterative refinement.
    prev = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      Code.compile_string(protocol_source, "synthesized_protocol.ex")
      :ok
    rescue
      e in CompileError ->
        {:error, Exception.message(e)}

      e ->
        {:error, "unexpected error: #{Exception.message(e)}"}
    after
      Code.put_compiler_option(:ignore_module_conflict, prev)
    end
  end

  # -- TLC Execution --

  # Run TLC model checking on a compiled protocol. Extracts the module name
  # from the source to locate the generated TLA+ files.
  defp run_tlc(protocol_source) do
    case extract_module_name(protocol_source) do
      nil ->
        {:error, "could not determine module name from protocol source"}

      mod_name ->
        # Use the existing mix task infrastructure to run TLC.
        # We shell out to `mix accord.check` to avoid duplicating the
        # TLC runner logic.
        case System.cmd("mix", ["accord.check", mod_name],
               cd: Mix.Project.app_path() |> Path.join("../../") |> Path.expand(),
               stderr_to_stdout: true
             ) do
          {output, 0} -> {:ok, output}
          {output, _} -> {:error, output}
        end
    end
  end

  defp extract_module_name(source) do
    case Regex.run(~r/defmodule\s+([\w.]+)/, source) do
      [_, name] -> name
      nil -> nil
    end
  end

  # -- Logging --

  defp log_iteration(channel, iteration, :ok) do
    Logger.info("[synthesize] #{channel} passed (iteration #{iteration})")
  end

  defp log_iteration(channel, iteration, :error) do
    Logger.info("[synthesize] #{channel} errors (iteration #{iteration}), refining...")
  end
end
