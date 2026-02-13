defmodule Accord.Test.ViolationCollector do
  @moduledoc """
  Collects violations via an ETS table shared across processes.

  The monitor's `{mod, fun}` violation policy calls `handle/1` inside
  the monitor process. Since the test process is separate, we use ETS
  (`:public`) so both sides can read/write without coordination.

  ## Usage

      # Before each test run:
      Accord.Test.ViolationCollector.init()

      Monitor.start_link(compiled,
        upstream: server,
        violation_policy: {Accord.Test.ViolationCollector, :handle})

      # ... run commands ...

      # After the run:
      prop_violations = Accord.Test.ViolationCollector.property_violations()
  """

  @table :accord_violation_collector

  @doc """
  Initializes (or resets) the collector. Call before each test run.
  """
  @spec init() :: :ok
  def init do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :ordered_set])
    end

    :ets.delete_all_objects(@table)
    :ok
  end

  @doc """
  Stores a violation. Called by the monitor via `{mod, fun}` policy.
  """
  @spec handle(Accord.Violation.t()) :: :ok
  def handle(violation) do
    # Use a monotonic key to preserve insertion order.
    key = :erlang.unique_integer([:monotonic])
    :ets.insert(@table, {key, violation})
    :ok
  end

  @doc """
  Drains all collected violations in insertion order and clears the table.
  """
  @spec drain() :: [Accord.Violation.t()]
  def drain do
    violations =
      case :ets.info(@table) do
        :undefined ->
          []

        # :ordered_set with monotonic keys — already sorted by insertion order.
        _ ->
          :ets.tab2list(@table)
          |> Enum.map(&elem(&1, 1))
      end

    if :ets.info(@table) != :undefined, do: :ets.delete_all_objects(@table)
    violations
  end

  @doc """
  Drains only property-blamed violations in insertion order.
  """
  @spec property_violations() :: [Accord.Violation.t()]
  def property_violations do
    drain() |> Enum.filter(&(&1.blame == :property))
  end
end
