defmodule Accord.Pass.TLA.BuildActionsTest do
  use ExUnit.Case, async: true

  alias Accord.IR
  alias Accord.IR.{Branch, State, Track, Transition}
  alias Accord.Pass.TLA.{BuildActions, BuildStateSpace}
  alias Accord.TLA.ModelConfig

  defp build(ir, config \\ %ModelConfig{}) do
    {:ok, ss} = BuildStateSpace.run(ir, config)
    {:ok, actions} = BuildActions.run(ir, ss, config)
    {ss, actions}
  end

  defp minimal_ir do
    %IR{
      name: Test.Protocol,
      initial: :ready,
      states: %{
        ready: %State{
          name: :ready,
          transitions: [
            %Transition{
              message_pattern: :go,
              message_types: [],
              kind: :call,
              branches: [%Branch{reply_type: {:literal, :ok}, next_state: :done}]
            }
          ]
        },
        done: %State{name: :done, terminal: true}
      }
    }
  end

  describe "call actions" do
    test "creates one action per state/transition/branch combination" do
      {_ss, actions} = build(minimal_ir())

      assert length(actions) == 1
      [action] = actions
      assert action.source_state == "ready"
      assert action.target_state == "done"
      assert action.message_tag == "go"
    end

    test "action name encodes source and target" do
      {_ss, actions} = build(minimal_ir())
      [action] = actions

      assert action.name == "GoFromReadyToDone"
    end

    test "state precondition matches source state" do
      {_ss, actions} = build(minimal_ir())
      [action] = actions

      assert ~s(state = "ready") in action.preconditions
    end

    test "primed state assignment matches target" do
      {_ss, actions} = build(minimal_ir())
      [action] = actions

      assert action.primed["state"] == ~s("done")
    end
  end

  describe "cast actions" do
    test "cast stays in same state" do
      ir = %{
        minimal_ir()
        | anystate: [
            %Transition{
              message_pattern: :heartbeat,
              message_types: [],
              kind: :cast,
              branches: []
            }
          ]
      }

      {_ss, actions} = build(ir)
      casts = Enum.filter(actions, &(&1.message_tag == "heartbeat"))

      assert length(casts) > 0

      Enum.each(casts, fn cast ->
        assert cast.source_state == cast.target_state
      end)
    end

    test "cast name includes Cast prefix" do
      ir = %{
        minimal_ir()
        | anystate: [
            %Transition{
              message_pattern: :heartbeat,
              message_types: [],
              kind: :cast,
              branches: []
            }
          ]
      }

      {_ss, actions} = build(ir)
      cast = Enum.find(actions, &(&1.message_tag == "heartbeat"))

      assert cast.name =~ "Cast"
    end
  end

  describe "existential variables" do
    test "typed message args become existential vars" do
      ir = %IR{
        name: Test.Protocol,
        initial: :ready,
        states: %{
          ready: %State{
            name: :ready,
            transitions: [
              %Transition{
                message_pattern: {:set, :_},
                message_types: [:integer],
                kind: :call,
                branches: [%Branch{reply_type: {:literal, :ok}, next_state: :ready}]
              }
            ]
          }
        }
      }

      config = %ModelConfig{domains: %{integer: -2..2}}
      {_ss, actions} = build(ir, config)
      [action] = actions

      assert length(action.existential_vars) == 1
      [{var_name, domain}] = action.existential_vars
      assert var_name =~ "msg_"
      assert domain == "-2..2"
    end

    test "no existential vars for bare atom messages" do
      {_ss, actions} = build(minimal_ir())
      [action] = actions

      assert action.existential_vars == []
    end
  end

  describe "guards as preconditions" do
    test "guard AST compiles to TLA+ precondition" do
      guard_ast = quote(do: fn {:bet, chips}, tracks -> chips <= tracks.balance end)

      ir = %IR{
        name: Test.Protocol,
        initial: :ready,
        tracks: [%Track{name: :balance, type: :integer, default: 100}],
        states: %{
          ready: %State{
            name: :ready,
            transitions: [
              %Transition{
                message_pattern: {:bet, :_},
                message_types: [:pos_integer],
                kind: :call,
                branches: [%Branch{reply_type: {:literal, :ok}, next_state: :ready}],
                guard: %{
                  fun: fn {:bet, chips}, tracks -> chips <= tracks.balance end,
                  ast: guard_ast
                }
              }
            ]
          }
        }
      }

      config = %ModelConfig{domains: %{balance: 0..100, pos_integer: 1..10}}
      {_ss, actions} = build(ir, config)
      [action] = actions

      # Guard should appear as a precondition beyond just the state check.
      assert length(action.preconditions) > 1
    end
  end

  describe "primed assignments" do
    test "update fn map updates become primed track assignments" do
      update_ast = quote(do: fn {:set, val}, _reply, tracks -> %{tracks | counter: val} end)

      ir = %IR{
        name: Test.Protocol,
        initial: :ready,
        tracks: [%Track{name: :counter, type: :integer, default: 0}],
        states: %{
          ready: %State{
            name: :ready,
            transitions: [
              %Transition{
                message_pattern: {:set, :_},
                message_types: [:integer],
                kind: :call,
                branches: [%Branch{reply_type: {:literal, :ok}, next_state: :ready}],
                update: %{
                  fun: fn {:set, val}, _reply, tracks -> %{tracks | counter: val} end,
                  ast: update_ast
                }
              }
            ]
          }
        }
      }

      config = %ModelConfig{domains: %{counter: 0..10, integer: 0..10}}
      {_ss, actions} = build(ir, config)
      [action] = actions

      assert Map.has_key?(action.primed, "counter")
    end
  end

  describe "UNCHANGED sets" do
    test "unmodified variables appear in unchanged" do
      ir = %IR{
        name: Test.Protocol,
        initial: :ready,
        tracks: [
          %Track{name: :x, type: :integer, default: 0},
          %Track{name: :y, type: :integer, default: 0}
        ],
        states: %{
          ready: %State{
            name: :ready,
            transitions: [
              %Transition{
                message_pattern: :go,
                message_types: [],
                kind: :call,
                branches: [%Branch{reply_type: {:literal, :ok}, next_state: :ready}]
              }
            ]
          }
        }
      }

      config = %ModelConfig{domains: %{x: 0..5, y: 0..5}}
      {_ss, actions} = build(ir, config)
      [action] = actions

      # No update fn, so tracks are unchanged.
      assert "x" in action.unchanged
      assert "y" in action.unchanged
    end

    test "state is not in unchanged when it changes" do
      {_ss, actions} = build(minimal_ir())
      [action] = actions

      # State changes from ready to done.
      refute "state" in action.unchanged
    end
  end

  describe "branching" do
    test "multiple branches produce multiple actions" do
      ir = %IR{
        name: Test.Protocol,
        initial: :ready,
        states: %{
          ready: %State{
            name: :ready,
            transitions: [
              %Transition{
                message_pattern: {:try, :_},
                message_types: [:integer],
                kind: :call,
                branches: [
                  %Branch{reply_type: {:literal, :ok}, next_state: :done},
                  %Branch{reply_type: {:tagged, :error, :atom}, next_state: :ready}
                ]
              }
            ]
          },
          done: %State{name: :done, terminal: true}
        }
      }

      config = %ModelConfig{domains: %{integer: 0..3}}
      {_ss, actions} = build(ir, config)

      try_actions = Enum.filter(actions, &(&1.message_tag == "try"))
      assert length(try_actions) == 2

      targets = Enum.map(try_actions, & &1.target_state) |> Enum.sort()
      assert targets == ["done", "ready"]
    end
  end
end
