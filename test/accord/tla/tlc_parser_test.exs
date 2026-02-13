defmodule Accord.TLA.TLCParserTest do
  use ExUnit.Case, async: true

  alias Accord.TLA.TLCParser

  # -- Success output --

  @success_output """
  TLC2 Version 2.18 of 22 July 2022
  Running breadth-first search Model-Checking with fp 93 and seed 1234

  Parsing file Protocol.tla
  Parsing file Integers.tla
  Semantic processing of module Protocol

  Computing initial states...
  Finished computing initial states: 1 distinct state generated.
  Progress(5) at 2023-03-09 15:53:05: 30 states generated (60 s/min), 12 distinct states found (24 ds/min), 0 states left on queue.
  Model checking completed. No error has been found.
  30 states generated, 12 distinct states found, 0 states left on queue.
  The depth of the complete state graph search is 5.
  Finished in 01s at (2023-03-09 15:53:06)
  """

  describe "success output" do
    test "parses successful model check" do
      assert {:ok, stats} = TLCParser.parse(@success_output)
      assert stats.states_generated == 30
      assert stats.distinct_states == 12
      assert stats.depth == 5
    end
  end

  # -- Invariant violation --

  @invariant_violation """
  TLC2 Version 2.18 of 22 July 2022
  Running breadth-first search Model-Checking with fp 93 and seed 1234

  Computing initial states...
  Finished computing initial states: 1 distinct state generated.

  Error: Invariant TokenNonNegative is violated.

  Error: The behavior up to this point is:

  State 1: <Initial predicate>
  /\\ state = "unlocked"
  /\\ fence_token = 0
  /\\ holder = NULL

  State 2: <AcquireFromUnlockedToLocked line 20, col 1 to line 30, col 40 of module Protocol>
  /\\ state = "locked"
  /\\ fence_token = 2
  /\\ holder = c1

  State 3: <AcquireFromLockedToLocked line 32, col 1 to line 42, col 40 of module Protocol>
  /\\ state = "locked"
  /\\ fence_token = -1
  /\\ holder = c2

  150 states generated, 42 distinct states found, 0 states left on queue.
  The depth of the complete state graph search is 3.
  Finished in 01s at (2023-03-09 15:53:06)
  """

  describe "invariant violation" do
    test "detects invariant violation" do
      assert {:error, violation, _stats} = TLCParser.parse(@invariant_violation)
      assert violation.kind == :invariant
      assert violation.property == "TokenNonNegative"
    end

    test "extracts counterexample trace" do
      {:error, violation, _stats} = TLCParser.parse(@invariant_violation)
      trace = violation.trace

      assert length(trace) == 3

      # State 1: initial.
      assert Enum.at(trace, 0).number == 1
      assert Enum.at(trace, 0).action == nil
      assert Enum.at(trace, 0).assignments["state"] == ~s("unlocked")
      assert Enum.at(trace, 0).assignments["fence_token"] == "0"

      # State 2: action.
      assert Enum.at(trace, 1).number == 2
      assert Enum.at(trace, 1).action == "AcquireFromUnlockedToLocked"
      assert Enum.at(trace, 1).assignments["state"] == ~s("locked")
      assert Enum.at(trace, 1).assignments["fence_token"] == "2"
      assert Enum.at(trace, 1).assignments["holder"] == "c1"

      # State 3: violating state.
      assert Enum.at(trace, 2).number == 3
      assert Enum.at(trace, 2).action == "AcquireFromLockedToLocked"
      assert Enum.at(trace, 2).assignments["fence_token"] == "-1"
    end

    test "extracts stats from violation output" do
      {:error, _violation, stats} = TLCParser.parse(@invariant_violation)
      assert stats.states_generated == 150
      assert stats.distinct_states == 42
      assert stats.depth == 3
    end
  end

  # -- Action property violation --

  @action_property_violation """
  TLC2 Version 2.18 of 22 July 2022
  Running breadth-first search Model-Checking with fp 93 and seed 1234

  Computing initial states...
  Finished computing initial states: 1 distinct state generated.

  Error: Action property MonotonicTokens is violated.

  Error: The behavior up to this point is:

  State 1: <Initial predicate>
  /\\ state = "unlocked"
  /\\ fence_token = 0
  /\\ holder = NULL

  State 2: <AcquireFromUnlockedToLocked line 20, col 1 to line 30, col 40 of module Protocol>
  /\\ state = "locked"
  /\\ fence_token = 3
  /\\ holder = c1

  State 3: <ReleaseFromLockedToUnlocked line 32, col 1 to line 42, col 40 of module Protocol>
  /\\ state = "unlocked"
  /\\ fence_token = 1
  /\\ holder = NULL

  55 states generated, 55 distinct states found, 0 states left on queue.
  The depth of the complete state graph search is 5.
  Finished in 01s at (2023-03-09 15:53:06)
  """

  describe "action property violation" do
    test "detects action property violation" do
      assert {:error, violation, _stats} = TLCParser.parse(@action_property_violation)
      assert violation.kind == :action_property
      assert violation.property == "MonotonicTokens"
    end

    test "extracts counterexample trace" do
      {:error, violation, _stats} = TLCParser.parse(@action_property_violation)
      assert length(violation.trace) == 3
      assert Enum.at(violation.trace, 2).assignments["fence_token"] == "1"
    end

    test "extracts stats" do
      {:error, _violation, stats} = TLCParser.parse(@action_property_violation)
      assert stats.states_generated == 55
      assert stats.distinct_states == 55
      assert stats.depth == 5
    end
  end

  # -- Deadlock --

  @deadlock_output """
  TLC2 Version 2.18 of 22 July 2022

  Computing initial states...
  Finished computing initial states: 1 distinct state generated.

  Error: Deadlock reached.

  Error: The behavior up to this point is:

  State 1: <Initial predicate>
  /\\ state = "ready"
  /\\ counter = 0

  State 2: <IncrementFromReadyToReady line 10, col 1 to line 15, col 20 of module Protocol>
  /\\ state = "ready"
  /\\ counter = 5

  5 states generated, 5 distinct states found, 0 states left on queue.
  The depth of the complete state graph search is 2.
  Finished in 01s at (2023-03-09 15:53:06)
  """

  describe "deadlock" do
    test "detects deadlock" do
      assert {:error, violation, _stats} = TLCParser.parse(@deadlock_output)
      assert violation.kind == :deadlock
      assert violation.property == nil
    end

    test "extracts deadlock trace" do
      {:error, violation, _stats} = TLCParser.parse(@deadlock_output)
      assert length(violation.trace) == 2
      assert Enum.at(violation.trace, 1).assignments["counter"] == "5"
    end
  end

  # -- Temporal violation (liveness) --

  @temporal_output """
  TLC2 Version 2.18 of 22 July 2022

  Computing initial states...
  Finished computing initial states: 1 distinct state generated.

  Checking temporal properties for the current state space with 743077 total distinct states

  Error: Temporal properties were violated.

  Error: The following behavior constitutes a counter-example:

  State 1: <Initial predicate>
  /\\ state = "unlocked"
  /\\ holder = NULL

  State 2: <AcquireFromUnlockedToLocked line 20, col 1 to line 30, col 40 of module Protocol>
  /\\ state = "locked"
  /\\ holder = c1

  Back to state 2: <AcquireFromLockedToLocked line 32, col 1 to line 42, col 40 of module Protocol>

  1486154 states generated, 743078 distinct states found, 1 states left on queue.
  Finished in 03s at (2023-03-09 15:53:06)
  """

  describe "temporal violation" do
    test "detects temporal property violation" do
      assert {:error, violation, _stats} = TLCParser.parse(@temporal_output)
      assert violation.kind == :temporal
    end

    test "extracts liveness counterexample trace" do
      {:error, violation, _stats} = TLCParser.parse(@temporal_output)
      trace = violation.trace

      # At least the initial state and the looping state.
      assert length(trace) >= 2

      assert Enum.at(trace, 0).number == 1
      assert Enum.at(trace, 0).assignments["state"] == ~s("unlocked")

      assert Enum.at(trace, 1).number == 2
      assert Enum.at(trace, 1).action == "AcquireFromUnlockedToLocked"
    end

    test "handles 'Back to state' loop markers" do
      {:error, violation, _stats} = TLCParser.parse(@temporal_output)
      trace = violation.trace

      # The "Back to state 2" should be parsed as a state entry.
      back_entry = Enum.at(trace, 2)
      assert back_entry.number == 2
      assert back_entry.action == "AcquireFromLockedToLocked"
    end

    test "extracts stats with large numbers" do
      {:error, _violation, stats} = TLCParser.parse(@temporal_output)
      assert stats.states_generated == 1_486_154
      assert stats.distinct_states == 743_078
    end
  end

  # -- Edge cases --

  describe "edge cases" do
    test "handles comma-separated state counts" do
      output = """
      Model checking completed. No error has been found.
      1,366,592,039 states generated, 199,817,884 distinct states found, 0 states left on queue.
      The depth of the complete state graph search is 42.
      """

      assert {:ok, stats} = TLCParser.parse(output)
      assert stats.states_generated == 1_366_592_039
      assert stats.distinct_states == 199_817_884
      assert stats.depth == 42
    end

    test "handles empty/unknown output gracefully" do
      assert {:error, violation, _stats} = TLCParser.parse("")
      assert violation.trace == []
    end

    test "parses trace with only initial state" do
      output = """
      Error: Invariant Bad is violated.

      Error: The behavior up to this point is:

      State 1: <Initial predicate>
      /\\ x = 0

      1 states generated, 1 distinct states found, 0 states left on queue.
      """

      {:error, violation, _stats} = TLCParser.parse(output)
      assert length(violation.trace) == 1
      assert Enum.at(violation.trace, 0).assignments["x"] == "0"
    end
  end
end
