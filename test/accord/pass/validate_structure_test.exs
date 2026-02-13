defmodule Accord.Pass.ValidateStructureTest do
  use ExUnit.Case, async: true

  alias Accord.IR
  alias Accord.IR.{Branch, State, Transition}
  alias Accord.Pass.ValidateStructure

  defp valid_ir do
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
            }
          ]
        },
        stopped: %State{name: :stopped, terminal: true}
      }
    }
  end

  test "accepts valid IR" do
    assert {:ok, _} = ValidateStructure.run(valid_ir())
  end

  test "rejects missing initial state" do
    ir = %{valid_ir() | initial: :nonexistent}
    assert {:error, [report]} = ValidateStructure.run(ir)
    assert report.message =~ "initial state :nonexistent is not defined"
  end

  test "rejects undefined goto target" do
    ir =
      put_in(valid_ir().states[:ready].transitions, [
        %Transition{
          message_pattern: :go,
          message_types: [],
          kind: :call,
          branches: [%Branch{reply_type: {:literal, :ok}, next_state: :nowhere}]
        }
      ])

    assert {:error, [report]} = ValidateStructure.run(ir)
    assert report.message =~ "undefined state reference :nowhere"
  end

  test "rejects terminal state with transitions" do
    ir =
      put_in(valid_ir().states[:stopped], %State{
        name: :stopped,
        terminal: true,
        transitions: [
          %Transition{
            message_pattern: :ping,
            message_types: [],
            kind: :call,
            branches: [%Branch{reply_type: {:literal, :pong}, next_state: :stopped}]
          }
        ]
      })

    assert {:error, [report]} = ValidateStructure.run(ir)
    assert report.message =~ "terminal state :stopped has transitions"
  end

  test "allows :__same__ as goto target" do
    ir = %{
      valid_ir()
      | anystate: [
          %Transition{
            message_pattern: :ping,
            message_types: [],
            kind: :call,
            branches: [%Branch{reply_type: {:literal, :pong}, next_state: :__same__}]
          }
        ]
    }

    assert {:ok, _} = ValidateStructure.run(ir)
  end

  test "collects multiple errors" do
    ir = %IR{
      name: Test,
      initial: :nonexistent,
      states: %{
        ready: %State{
          name: :ready,
          transitions: [
            %Transition{
              message_pattern: :go,
              message_types: [],
              kind: :call,
              branches: [%Branch{reply_type: {:literal, :ok}, next_state: :also_nonexistent}]
            }
          ]
        }
      }
    }

    assert {:error, errors} = ValidateStructure.run(ir)
    assert length(errors) == 2
  end
end
