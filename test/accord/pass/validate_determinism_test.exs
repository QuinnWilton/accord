defmodule Accord.Pass.ValidateDeterminismTest do
  use ExUnit.Case, async: true

  alias Accord.IR
  alias Accord.IR.{Branch, State, Transition}
  alias Accord.Pass.ValidateDeterminism

  defp base_ir(opts) do
    transitions = Keyword.get(opts, :transitions, [])
    anystate = Keyword.get(opts, :anystate, [])

    %IR{
      name: Test,
      initial: :ready,
      states: %{
        ready: %State{name: :ready, transitions: transitions},
        stopped: %State{name: :stopped, terminal: true}
      },
      anystate: anystate
    }
  end

  defp call_transition(pattern, next_state \\ :ready) do
    %Transition{
      message_pattern: pattern,
      message_types: [],
      kind: :call,
      branches: [%Branch{reply_type: :term, next_state: next_state}]
    }
  end

  test "accepts deterministic transitions" do
    ir =
      base_ir(
        transitions: [
          call_transition(:ping),
          call_transition(:stop, :stopped)
        ]
      )

    assert {:ok, _} = ValidateDeterminism.run(ir)
  end

  test "rejects duplicate message tags in same state" do
    ir =
      base_ir(
        transitions: [
          call_transition(:ping),
          call_transition(:ping)
        ]
      )

    assert {:error, [report]} = ValidateDeterminism.run(ir)
    assert report.message =~ "ambiguous dispatch"
    assert report.message =~ ":ping"
  end

  test "rejects state transition conflicting with anystate" do
    ir =
      base_ir(
        transitions: [call_transition(:ping)],
        anystate: [call_transition(:ping)]
      )

    assert {:error, [report]} = ValidateDeterminism.run(ir)
    assert report.message =~ "ambiguous dispatch"
  end

  test "allows same message tag in different states" do
    ir = %IR{
      name: Test,
      initial: :a,
      states: %{
        a: %State{name: :a, transitions: [call_transition(:ping, :b)]},
        b: %State{name: :b, transitions: [call_transition(:ping, :a)]},
        done: %State{name: :done, terminal: true}
      }
    }

    assert {:ok, _} = ValidateDeterminism.run(ir)
  end

  test "skips terminal states" do
    ir = %IR{
      name: Test,
      initial: :ready,
      states: %{
        ready: %State{name: :ready, transitions: [call_transition(:stop, :stopped)]},
        stopped: %State{name: :stopped, terminal: true}
      },
      anystate: [call_transition(:ping)]
    }

    # :ping in anystate should not conflict with terminal state.
    assert {:ok, _} = ValidateDeterminism.run(ir)
  end

  test "detects ambiguity with tuple message tags" do
    ir =
      base_ir(
        transitions: [
          call_transition({:get, :_}),
          call_transition({:get, :_})
        ]
      )

    assert {:error, [report]} = ValidateDeterminism.run(ir)
    assert report.message =~ ":get"
  end
end
