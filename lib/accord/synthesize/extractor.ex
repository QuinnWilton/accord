defmodule Accord.Synthesize.Extractor do
  @moduledoc """
  Fact extraction from OTP modules for protocol synthesis.

  When Argus is available (optional dependency), extracts rich structural
  facts from bytecode: states, transitions, timeouts, API surface, and
  supervision topology. Falls back to lightweight detection from module
  info or source-level regex when Argus is not present.

  The LLM handles the semantic analysis (message patterns, types, guards,
  properties) by reading source code directly. This module provides the
  structural scaffold that orients the LLM before it reads the source.
  """

  @type facts :: %{
          module: module(),
          behaviour: :gen_server | :gen_statem | nil,
          callback_mode: :state_functions | :handle_event_function | nil,
          exports: [{atom(), non_neg_integer()}],
          source_file: String.t() | nil,
          states: [atom()],
          transitions: [{from :: atom(), event :: String.t(), to :: atom()}],
          timeouts: [{state :: atom(), type :: String.t(), value :: String.t()}],
          sync_calls: [String.t()],
          async_casts: [String.t()]
        }

  @doc """
  Extract structural facts from a compiled OTP module.

  Uses Argus for bytecode-level extraction when available. Falls back to
  module info inspection otherwise. The module must be compiled and loaded.
  """
  @spec extract(module()) :: {:ok, facts()} | {:error, :not_loaded}
  def extract(mod) do
    unless Code.ensure_loaded?(mod) do
      {:error, :not_loaded}
    else
      base = %{
        module: mod,
        behaviour: detect_behaviour(mod),
        callback_mode: detect_callback_mode(mod),
        exports: mod.__info__(:functions),
        source_file: source_file(mod),
        states: detect_states(mod),
        transitions: [],
        timeouts: [],
        sync_calls: [],
        async_casts: []
      }

      {:ok, maybe_enrich_with_argus(base, mod)}
    end
  end

  @doc """
  Extract structural facts from a source file without compilation.

  Parses the source text with regex to detect the OTP behaviour, module name,
  and callback mode. Less precise than `extract/1` but works on any file
  without needing it on the code path.
  """
  @spec extract_from_source(String.t(), String.t()) :: {:ok, facts()}
  def extract_from_source(source, file_path) do
    {:ok,
     %{
       module: detect_module_name(source),
       behaviour: detect_behaviour_from_source(source),
       callback_mode: detect_callback_mode_from_source(source),
       exports: [],
       source_file: file_path,
       states: detect_states_from_source(source),
       transitions: [],
       timeouts: [],
       sync_calls: [],
       async_casts: []
     }}
  end

  @doc """
  Read the source code for a compiled module.

  Uses the compile-time source path stored in the module's debug info.
  Returns `{:ok, source}` or `{:error, reason}`.
  """
  @spec read_source(module()) :: {:ok, String.t()} | {:error, :no_source | File.posix()}
  def read_source(mod) do
    case source_file(mod) do
      nil -> {:error, :no_source}
      path -> File.read(path)
    end
  end

  # -- Argus Integration --

  @argus_extractors (if Code.ensure_loaded?(Argus.Extract) do
                       [Argus.Extractors.OTP, Argus.Extractors.GenStatem]
                     else
                       nil
                     end)

  defp maybe_enrich_with_argus(facts, mod) do
    if @argus_extractors do
      enrich_with_argus(facts, mod)
    else
      facts
    end
  end

  defp enrich_with_argus(facts, mod) do
    case Argus.Extract.extract([mod], extractors: @argus_extractors) do
      {:ok, argus_facts} ->
        %{
          facts
          | states: merge_states(facts.states, argus_facts),
            transitions: extract_transitions(argus_facts),
            timeouts: extract_timeouts(argus_facts),
            sync_calls: extract_sync_calls(argus_facts),
            async_casts: extract_async_casts(argus_facts)
        }

      {:error, _reason} ->
        facts
    end
  rescue
    _ -> facts
  end

  defp merge_states(existing, argus_facts) do
    argus_states =
      (argus_facts[:statem_state] || [])
      |> Enum.map(fn [_mod, state] -> String.to_atom(state) end)

    (existing ++ argus_states) |> Enum.uniq() |> Enum.sort()
  end

  defp extract_transitions(argus_facts) do
    (argus_facts[:statem_transition] || [])
    |> Enum.map(fn [_mod, from, event, to] ->
      {String.to_atom(from), event, String.to_atom(to)}
    end)
  end

  defp extract_timeouts(argus_facts) do
    (argus_facts[:statem_timeout] || [])
    |> Enum.map(fn [_mod, state, type, value] ->
      {String.to_atom(state), type, value}
    end)
  end

  defp extract_sync_calls(argus_facts) do
    (argus_facts[:sync_call] || [])
    |> Enum.map(fn [caller, _callee] -> caller end)
    |> Enum.uniq()
  end

  defp extract_async_casts(argus_facts) do
    (argus_facts[:async_cast] || [])
    |> Enum.map(fn [caller, _callee] -> caller end)
    |> Enum.uniq()
  end

  # -- Behaviour Detection --

  defp detect_behaviour(mod) do
    behaviours =
      (mod.module_info(:attributes)[:behaviour] || []) ++
        (mod.module_info(:attributes)[:behavior] || [])

    cond do
      :gen_statem in behaviours -> :gen_statem
      GenServer in behaviours or :gen_server in behaviours -> :gen_server
      true -> nil
    end
  end

  # -- Callback Mode Detection --

  # For gen_statem, the callback_mode/0 function determines how states
  # are dispatched. This affects how we interpret exports as states.
  defp detect_callback_mode(mod) do
    if function_exported?(mod, :callback_mode, 0) do
      case mod.callback_mode() do
        mode when is_atom(mode) ->
          normalize_callback_mode(mode)

        modes when is_list(modes) ->
          modes |> Enum.find(&state_dispatch?/1) |> normalize_callback_mode()
      end
    end
  rescue
    # callback_mode/0 may have side effects or require initialization.
    _ -> nil
  end

  defp normalize_callback_mode(:state_functions), do: :state_functions
  defp normalize_callback_mode(:handle_event_function), do: :handle_event_function
  defp normalize_callback_mode(_), do: nil

  defp state_dispatch?(:state_functions), do: true
  defp state_dispatch?(:handle_event_function), do: true
  defp state_dispatch?(_), do: false

  # -- State Detection --

  # Standard gen_statem callbacks that are NOT state names.
  @non_state_callbacks ~w(
    init callback_mode handle_event terminate code_change format_status
  )a

  defp detect_states(mod) do
    case detect_behaviour(mod) do
      :gen_statem -> detect_statem_states(mod)
      _ -> []
    end
  end

  # For state_functions mode, each exported 3-arity function (excluding
  # standard callbacks) is a state handler.
  defp detect_statem_states(mod) do
    case detect_callback_mode(mod) do
      :state_functions ->
        mod.__info__(:functions)
        |> Enum.filter(fn {name, arity} ->
          arity == 3 and name not in @non_state_callbacks
        end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      _ ->
        # handle_event_function mode: states are not directly inferrable
        # from exports. The LLM will need to read the source.
        []
    end
  end

  # -- Source-Based Detection (regex, no compilation) --

  defp detect_module_name(source) do
    case Regex.run(~r/defmodule\s+([\w.]+)/, source) do
      [_, name] -> Module.concat([name])
      nil -> Unknown
    end
  end

  defp detect_behaviour_from_source(source) do
    cond do
      source =~ ~r/use\s+GenServer/ or source =~ ~r/@behaviour\s+GenServer/ ->
        :gen_server

      source =~ ~r/:gen_statem/ or source =~ ~r/@behaviour\s+:gen_statem/ ->
        :gen_statem

      true ->
        nil
    end
  end

  defp detect_callback_mode_from_source(source) do
    # Matches both `def callback_mode, do: :state_functions` and
    # `def callback_mode() do\n  :state_functions\nend` forms.
    case Regex.run(~r/def\s+callback_mode[\s\(\),]+(?:do:?\s+):?(\w+)/s, source) do
      [_, "state_functions"] -> :state_functions
      [_, "handle_event_function"] -> :handle_event_function
      _ -> nil
    end
  end

  # Scan for `def state_name(event_type, event, data)` patterns in gen_statem
  # source using state_functions mode. Matches both `def idle(:cast, ...)` and
  # `def idle({:call, from}, ...)` forms.
  defp detect_states_from_source(source) do
    if detect_callback_mode_from_source(source) == :state_functions do
      Regex.scan(
        ~r/^\s*def\s+(\w+)\s*\(\s*(?::call|:cast|:info|:timeout|:internal|\{:call|event_type)/m,
        source,
        capture: :all_but_first
      )
      |> Enum.map(fn [name] -> String.to_atom(name) end)
      |> Enum.reject(&(&1 in @non_state_callbacks))
      |> Enum.uniq()
      |> Enum.sort()
    else
      []
    end
  end

  # -- Source File --

  defp source_file(mod) do
    case mod.module_info(:compile)[:source] do
      nil -> nil
      charlist when is_list(charlist) -> List.to_string(charlist)
      binary when is_binary(binary) -> binary
    end
  rescue
    _ -> nil
  end
end
