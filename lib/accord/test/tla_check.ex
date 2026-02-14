defmodule Accord.Test.TLACheck do
  @moduledoc """
  Test assertions for TLA+ model checking.

  Provides helpers for running TLC against protocol modules and asserting
  that model checking either passes or fails with the expected violation kind.

  ## Usage in tests

      @moduletag :tlc
      @moduletag :tmp_dir

      test "counter passes", %{tmp_dir: tmp_dir} do
        assert_passes(Accord.Test.Counter.Protocol, tmp_dir: tmp_dir)
      end

      test "invariant fails", %{tmp_dir: tmp_dir} do
        assert_fails(Accord.Test.InvariantFail.Protocol, :invariant, tmp_dir: tmp_dir)
      end

  ## TLC discovery

  Looks for `tla2tools.jar` in the same locations as `mix accord.check`:

  1. `TLA2TOOLS_JAR` environment variable
  2. `~/.tla/tla2tools.jar`
  3. `tla2tools.jar` in the current directory
  """

  alias Accord.TLA.{Compiler, ModelConfig, TLCParser}

  @doc """
  Returns `true` if Java and `tla2tools.jar` are both available.
  """
  @spec tlc_available?() :: boolean()
  def tlc_available? do
    java_available?() and find_tlc_jar() != nil
  end

  @doc """
  Compiles TLA+ from the protocol's IR, runs TLC, and asserts success.

  Raises `ExUnit.AssertionError` if model checking finds any violation.

  ## Options

  - `:tmp_dir` (required) — working directory for TLA+ files and TLC state
  - `:model_config` — a `%ModelConfig{}` struct (overrides file-based config)
  - `:model_config_path` — path to a model config file
  - `:check_deadlock` — when `true`, enables TLC deadlock checking (default: `false`)
  """
  @spec assert_passes(module(), keyword()) :: :ok
  def assert_passes(protocol_mod, opts) do
    tmp_dir = Keyword.fetch!(opts, :tmp_dir)
    result = run_tlc(protocol_mod, tmp_dir, opts)

    case result do
      {:ok, _stats} ->
        :ok

      {:error, violation, _stats} ->
        raise ExUnit.AssertionError,
          message:
            "expected model checking to pass, but got #{violation.kind} violation" <>
              if(violation.property, do: " (#{violation.property})", else: "") <>
              format_trace_summary(violation.trace)
    end
  end

  @doc """
  Compiles TLA+ from the protocol's IR, runs TLC, and asserts failure
  with the expected violation kind.

  Raises `ExUnit.AssertionError` if model checking passes or fails with
  a different violation kind.

  ## Options

  Same as `assert_passes/2`.
  """
  @spec assert_fails(module(), atom(), keyword()) :: :ok
  def assert_fails(protocol_mod, expected_kind, opts) do
    tmp_dir = Keyword.fetch!(opts, :tmp_dir)
    result = run_tlc(protocol_mod, tmp_dir, opts)

    case result do
      {:ok, _stats} ->
        raise ExUnit.AssertionError,
          message: "expected #{expected_kind} violation, but model checking passed"

      {:error, %{kind: ^expected_kind}, _stats} ->
        :ok

      {:error, %{kind: actual_kind} = violation, _stats} ->
        raise ExUnit.AssertionError,
          message:
            "expected #{expected_kind} violation, but got #{actual_kind}" <>
              if(violation.property, do: " (#{violation.property})", else: "") <>
              format_trace_summary(violation.trace)
    end
  end

  # -- Internals --

  defp run_tlc(protocol_mod, tmp_dir, opts) do
    ir = protocol_mod.__ir__()
    config = resolve_config(protocol_mod, opts)
    {:ok, result} = Compiler.compile(ir, config)

    # The TLA+ filename must match the MODULE name inside the file.
    module_name = result.state_space.module_name
    tla_file = "#{module_name}.tla"
    cfg_file = "#{module_name}.cfg"

    File.write!(Path.join(tmp_dir, tla_file), result.tla)
    File.write!(Path.join(tmp_dir, cfg_file), result.cfg)

    tlc_jar = find_tlc_jar() || raise "tla2tools.jar not found"
    check_deadlock = Keyword.get(opts, :check_deadlock, false)

    args =
      ["-jar", tlc_jar, "-config", cfg_file] ++
        if(check_deadlock, do: [], else: ["-deadlock"]) ++
        ["-cleanup", tla_file]

    case System.cmd("java", args, cd: tmp_dir, stderr_to_stdout: true) do
      {output, _exit_code} -> TLCParser.parse(output)
    end
  end

  defp resolve_config(_protocol_mod, opts) do
    cond do
      config = Keyword.get(opts, :model_config) ->
        config

      path = Keyword.get(opts, :model_config_path) ->
        ModelConfig.load(protocol_config_path: path)

      true ->
        ModelConfig.load()
    end
  end

  defp java_available? do
    case System.cmd("java", ["-version"], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    ErlangError -> false
  end

  defp find_tlc_jar do
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

  defp format_trace_summary([]), do: ""

  defp format_trace_summary(trace) do
    steps =
      Enum.map_join(trace, " → ", fn entry ->
        entry.action || "Init"
      end)

    "\n  trace: #{steps}"
  end
end
