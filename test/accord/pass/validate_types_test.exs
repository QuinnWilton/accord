defmodule Accord.Pass.ValidateTypesTest do
  use ExUnit.Case, async: true

  alias Accord.IR
  alias Accord.IR.{Branch, State, Track, Transition}
  alias Accord.Pass.ValidateTypes

  defp base_ir(opts) do
    tracks = Keyword.get(opts, :tracks, [])
    transitions = Keyword.get(opts, :transitions, [])
    anystate = Keyword.get(opts, :anystate, [])

    %IR{
      name: Test,
      initial: :ready,
      tracks: tracks,
      states: %{
        ready: %State{name: :ready, transitions: transitions},
        stopped: %State{name: :stopped, terminal: true}
      },
      anystate: anystate
    }
  end

  test "accepts valid IR with no tracks" do
    ir =
      base_ir(
        transitions: [
          %Transition{
            message_pattern: :stop,
            message_types: [],
            kind: :call,
            branches: [%Branch{reply_type: {:literal, :stopped}, next_state: :stopped}]
          }
        ]
      )

    assert {:ok, _} = ValidateTypes.run(ir)
  end

  test "accepts valid track defaults" do
    ir =
      base_ir(
        tracks: [
          %Track{name: :counter, type: :integer, default: 0},
          %Track{name: :name, type: :string, default: ""},
          %Track{name: :holder, type: :term, default: nil}
        ]
      )

    assert {:ok, _} = ValidateTypes.run(ir)
  end

  test "rejects track default that doesn't conform to type" do
    ir =
      base_ir(
        tracks: [
          %Track{name: :counter, type: :pos_integer, default: 0}
        ]
      )

    assert {:error, [report]} = ValidateTypes.run(ir)
    assert report.message =~ "track :counter default 0 does not conform to type pos_integer()"
  end

  test "rejects call transition with no branches" do
    ir =
      base_ir(
        transitions: [
          %Transition{
            message_pattern: :ping,
            message_types: [],
            kind: :call,
            branches: []
          }
        ]
      )

    assert {:error, [report]} = ValidateTypes.run(ir)
    assert report.message =~ "call transition has no branches"
  end

  test "accepts cast with no branches" do
    ir =
      base_ir(
        anystate: [
          %Transition{
            message_pattern: :heartbeat,
            message_types: [],
            kind: :cast,
            branches: []
          }
        ]
      )

    assert {:ok, _} = ValidateTypes.run(ir)
  end
end
