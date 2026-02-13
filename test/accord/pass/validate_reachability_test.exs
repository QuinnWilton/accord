defmodule Accord.Pass.ValidateReachabilityTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Accord.IR
  alias Accord.IR.{Branch, State, Transition}
  alias Accord.Pass.ValidateReachability

  defp base_ir do
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

  test "accepts fully reachable IR" do
    assert {:ok, _} = ValidateReachability.run(base_ir())
    assert ValidateReachability.warnings(base_ir()) == []
  end

  test "warns on unreachable non-terminal state" do
    ir =
      put_in(base_ir().states[:orphan], %State{
        name: :orphan,
        transitions: [
          %Transition{
            message_pattern: :ping,
            message_types: [],
            kind: :call,
            branches: [%Branch{reply_type: {:literal, :pong}, next_state: :orphan}]
          }
        ]
      })

    # run/1 always succeeds (warnings are advisory).
    assert {:ok, _} = ValidateReachability.run(ir)

    warnings = ValidateReachability.warnings(ir)
    assert length(warnings) == 1
    assert hd(warnings).message =~ "unreachable"
    assert hd(warnings).message =~ ":orphan"
  end

  test "does not warn on unreachable terminal state" do
    ir =
      put_in(base_ir().states[:dead], %State{
        name: :dead,
        terminal: true
      })

    assert ValidateReachability.warnings(ir) == []
  end

  test "warns when no terminal state is reachable" do
    ir = %IR{
      name: Test,
      initial: :a,
      states: %{
        a: %State{
          name: :a,
          transitions: [
            %Transition{
              message_pattern: :go,
              message_types: [],
              kind: :call,
              branches: [%Branch{reply_type: {:literal, :ok}, next_state: :b}]
            }
          ]
        },
        b: %State{
          name: :b,
          transitions: [
            %Transition{
              message_pattern: :back,
              message_types: [],
              kind: :call,
              branches: [%Branch{reply_type: {:literal, :ok}, next_state: :a}]
            }
          ]
        },
        terminal: %State{name: :terminal, terminal: true}
      }
    }

    warnings = ValidateReachability.warnings(ir)
    messages = Enum.map(warnings, & &1.message)
    assert Enum.any?(messages, &(&1 =~ "no terminal state is reachable"))
  end

  test "follows anystate transitions for reachability" do
    ir = %IR{
      name: Test,
      initial: :a,
      states: %{
        a: %State{name: :a},
        b: %State{name: :b},
        done: %State{name: :done, terminal: true}
      },
      anystate: [
        %Transition{
          message_pattern: :jump,
          message_types: [],
          kind: :call,
          branches: [%Branch{reply_type: {:literal, :ok}, next_state: :b}]
        },
        %Transition{
          message_pattern: :finish,
          message_types: [],
          kind: :call,
          branches: [%Branch{reply_type: {:literal, :done}, next_state: :done}]
        }
      ]
    }

    assert ValidateReachability.warnings(ir) == []
  end

  test "handles branching transitions" do
    ir = %IR{
      name: Test,
      initial: :start,
      states: %{
        start: %State{
          name: :start,
          transitions: [
            %Transition{
              message_pattern: :go,
              message_types: [],
              kind: :call,
              branches: [
                %Branch{reply_type: {:literal, :ok}, next_state: :a},
                %Branch{reply_type: {:literal, :err}, next_state: :b}
              ]
            }
          ]
        },
        a: %State{
          name: :a,
          transitions: [
            %Transition{
              message_pattern: :stop,
              message_types: [],
              kind: :call,
              branches: [%Branch{reply_type: {:literal, :done}, next_state: :done}]
            }
          ]
        },
        b: %State{
          name: :b,
          transitions: [
            %Transition{
              message_pattern: :stop,
              message_types: [],
              kind: :call,
              branches: [%Branch{reply_type: {:literal, :done}, next_state: :done}]
            }
          ]
        },
        done: %State{name: :done, terminal: true}
      }
    }

    assert ValidateReachability.warnings(ir) == []
  end

  test "no warning when no terminal states defined" do
    ir = %IR{
      name: Test,
      initial: :only,
      states: %{
        only: %State{name: :only}
      }
    }

    assert ValidateReachability.warnings(ir) == []
  end
end
