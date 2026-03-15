defmodule Accord.Synthesize do
  @moduledoc """
  Neurosymbolic protocol synthesis from OTP modules.

  Orchestrates the synthesis pipeline: extract structural facts from a
  compiled OTP module, build an LLM prompt, synthesize an Accord protocol,
  validate it through Accord's compilation passes, and optionally verify
  with TLC model checking.

  All LLM interaction is contained within the `Accord.Synthesize` namespace.
  The core Accord library (IR, passes, monitor, TLA+) has no dependency on
  this module — synthesis is a pure consumer of the existing infrastructure.

  ## Architecture

  ```
  OTP Module
       │
       ├─ Extractor: structural facts (behaviour, states, exports)
       ├─ Source: full Elixir source code
       │
       ▼
  Prompt: DSL reference + examples + facts + source
       │
       ▼
  CLI: claude -p → LLM response
       │
       ▼
  Refinement Channel 1: Accord validation loop
       │
       ▼
  Output: protocols/<module>_protocol.ex
       │
       ▼ (optional)
  Refinement Channel 2: TLC model checking loop
  ```
  """

  alias Accord.Synthesize.{CLI, Extractor, Prompt, Refinement}

  require Logger

  @type option ::
          {:output_dir, String.t()}
          | {:check, boolean()}
          | {:dry_run, boolean()}
          | {:max_validation_iterations, pos_integer()}
          | {:max_tlc_iterations, pos_integer()}

  @doc """
  Synthesize an Accord protocol for the given OTP module.

  ## Options

    * `:output_dir` — directory for generated protocol files (default: `"protocols"`)
    * `:check` — run TLC model checking after synthesis (default: `false`)
    * `:dry_run` — print the prompt without invoking the LLM (default: `false`)
    * `:max_validation_iterations` — max Channel 1 retries (default: `5`)
    * `:max_tlc_iterations` — max Channel 2 retries (default: `3`)

  Returns `{:ok, output_path}` on success or `{:error, reason}` on failure.
  """
  @spec run(module(), [option()]) :: {:ok, String.t()} | {:error, term()}
  def run(mod, opts \\ []) do
    output_dir = Keyword.get(opts, :output_dir, "protocols")
    check? = Keyword.get(opts, :check, false)
    dry_run? = Keyword.get(opts, :dry_run, false)

    # Phase 1: Extract facts and source.
    with {:ok, facts} <- Extractor.extract(mod),
         {:ok, source} <- Extractor.read_source(mod) do
      prompt = Prompt.build(facts, source)

      if dry_run? do
        {:ok, prompt}
      else
        synthesize(prompt, facts, source, output_dir, check?, opts)
      end
    end
  end

  @doc """
  Synthesize an Accord protocol from a source file path.

  Does not require the module to be compiled or loaded. Extracts facts
  from the source text using regex-based detection. Useful for pointing
  at modules in sibling projects or arbitrary Elixir files.

  Accepts the same options as `run/2`.
  """
  @spec run_from_file(String.t(), [option()]) :: {:ok, String.t()} | {:error, term()}
  def run_from_file(file_path, opts \\ []) do
    output_dir = Keyword.get(opts, :output_dir, "protocols")
    check? = Keyword.get(opts, :check, false)
    dry_run? = Keyword.get(opts, :dry_run, false)

    with {:ok, source} <- File.read(file_path),
         {:ok, facts} <- Extractor.extract_from_source(source, file_path) do
      prompt = Prompt.build(facts, source)

      if dry_run? do
        {:ok, prompt}
      else
        synthesize(prompt, facts, source, output_dir, check?, opts)
      end
    end
  end

  defp synthesize(prompt, facts, source, output_dir, check?, opts) do
    # Phase 2: LLM synthesis.
    with {:ok, response} <- CLI.complete(prompt) do
      protocol_source = Prompt.extract_code_block(response)

      # Phase 3: Validation loop (Channel 1).
      validation_opts = [
        max_iterations: Keyword.get(opts, :max_validation_iterations, 5)
      ]

      case Refinement.validation_loop(protocol_source, facts, source, validation_opts) do
        {:ok, validated_source} ->
          # Phase 4: Write output.
          output_path = output_path(facts.module, output_dir)
          File.mkdir_p!(Path.dirname(output_path))
          File.write!(output_path, validated_source)
          Logger.info("[synthesize] wrote #{output_path}")

          # Phase 5: Optional TLC (Channel 2).
          if check? do
            tlc_opts = [
              max_iterations: Keyword.get(opts, :max_tlc_iterations, 3)
            ]

            case Refinement.tlc_loop(
                   validated_source,
                   output_path,
                   facts,
                   source,
                   tlc_opts
                 ) do
              {:ok, _final_source} ->
                {:ok, output_path}

              {:error, reason, _source} ->
                Logger.warning("[synthesize] TLC refinement failed: #{inspect(reason)}")
                # Still return success — the protocol compiled, just TLC didn't pass.
                {:ok, output_path}
            end
          else
            {:ok, output_path}
          end

        {:error, :max_iterations, _source} ->
          {:error, :validation_failed}

        {:error, reason, _detail} ->
          {:error, reason}
      end
    end
  end

  # Derive the output file path from the module name.
  # MyApp.Counter → protocols/my_app/counter_protocol.ex
  @spec output_path(module(), String.t()) :: String.t()
  defp output_path(mod, output_dir) do
    parts = Module.split(mod)

    dir_parts =
      parts
      |> Enum.slice(0..-2//1)
      |> Enum.map(&Macro.underscore/1)

    base_name =
      parts
      |> List.last()
      |> Macro.underscore()

    Path.join([output_dir | dir_parts] ++ ["#{base_name}_protocol.ex"])
  end
end
