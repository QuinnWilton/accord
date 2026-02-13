defmodule Accord.Pass.BuildTransitionTableTest do
  use ExUnit.Case, async: true

  alias Accord.IR
  alias Accord.IR.{Branch, State, Transition}
  alias Accord.Monitor.TransitionTable
  alias Accord.Pass.BuildTransitionTable

  defp sample_ir do
    %IR{
      name: Test,
      initial: :ready,
      states: %{
        ready: %State{
          name: :ready,
          transitions: [
            %Transition{
              message_pattern: :stop,
              message_types: [],
              kind: :call,
              branches: [%Branch{reply_type: {:literal, :stopped}, next_state: :stopped}]
            },
            %Transition{
              message_pattern: {:increment, :_},
              message_types: [:pos_integer],
              kind: :call,
              branches: [%Branch{reply_type: {:tagged, :ok, :integer}, next_state: :ready}]
            }
          ]
        },
        stopped: %State{name: :stopped, terminal: true}
      },
      anystate: [
        %Transition{
          message_pattern: :ping,
          message_types: [],
          kind: :call,
          branches: [%Branch{reply_type: {:literal, :pong}, next_state: :__same__}]
        },
        %Transition{
          message_pattern: :heartbeat,
          message_types: [],
          kind: :cast,
          branches: []
        }
      ]
    }
  end

  test "builds table from IR" do
    assert {:ok, %TransitionTable{} = table} = BuildTransitionTable.run(sample_ir())
    assert is_map(table.table)
  end

  test "state transitions are keyed by (state, tag)" do
    {:ok, table} = BuildTransitionTable.run(sample_ir())
    assert {:ok, t} = TransitionTable.lookup(table, :ready, :stop)
    assert t.message_pattern == :stop
  end

  test "tuple message uses first element as tag" do
    {:ok, table} = BuildTransitionTable.run(sample_ir())
    assert {:ok, t} = TransitionTable.lookup(table, :ready, {:increment, 5})
    assert t.message_pattern == {:increment, :_}
  end

  test "anystate transitions are merged into non-terminal states" do
    {:ok, table} = BuildTransitionTable.run(sample_ir())
    assert {:ok, t} = TransitionTable.lookup(table, :ready, :ping)
    assert t.message_pattern == :ping
  end

  test "anystate cast is merged" do
    {:ok, table} = BuildTransitionTable.run(sample_ir())
    assert {:ok, t} = TransitionTable.lookup(table, :ready, :heartbeat)
    assert t.kind == :cast
  end

  test "terminal states have no entries" do
    {:ok, table} = BuildTransitionTable.run(sample_ir())
    assert :error = TransitionTable.lookup(table, :stopped, :ping)
    assert :error = TransitionTable.lookup(table, :stopped, :stop)
  end

  test "terminal_states is populated" do
    {:ok, table} = BuildTransitionTable.run(sample_ir())
    assert TransitionTable.terminal?(table, :stopped)
    refute TransitionTable.terminal?(table, :ready)
  end

  test "lookup returns :error for unknown state/message" do
    {:ok, table} = BuildTransitionTable.run(sample_ir())
    assert :error = TransitionTable.lookup(table, :ready, :unknown)
    assert :error = TransitionTable.lookup(table, :nonexistent, :ping)
  end
end
