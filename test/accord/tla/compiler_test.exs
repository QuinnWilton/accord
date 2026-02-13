defmodule Accord.TLA.CompilerTest do
  use ExUnit.Case, async: true

  alias Accord.IR
  alias Accord.IR.{Branch, Check, Property, State, Track, Transition}
  alias Accord.Pass.TLA.{BuildActions, BuildProperties, BuildStateSpace}
  alias Accord.TLA.{Compiler, ModelConfig}

  # -- Fixtures --

  defp lock_ir do
    %IR{
      name: Lock.Protocol,
      initial: :unlocked,
      tracks: [
        %Track{name: :holder, type: :term, default: nil},
        %Track{name: :fence_token, type: :non_neg_integer, default: 0}
      ],
      states: %{
        unlocked: %State{
          name: :unlocked,
          transitions: [
            %Transition{
              message_pattern: {:acquire, :_},
              message_types: [:term],
              kind: :call,
              branches: [%Branch{reply_type: {:tagged, :ok, :pos_integer}, next_state: :locked}],
              update: %{
                fun: fn {:acquire, cid}, {:ok, token}, tracks ->
                  %{tracks | holder: cid, fence_token: token}
                end,
                ast:
                  quote(
                    do: fn {:acquire, cid}, {:ok, token}, tracks ->
                      %{tracks | holder: cid, fence_token: token}
                    end
                  )
              }
            }
          ]
        },
        locked: %State{
          name: :locked,
          transitions: [
            %Transition{
              message_pattern: {:release, :_},
              message_types: [:pos_integer],
              kind: :call,
              branches: [
                %Branch{reply_type: {:literal, :ok}, next_state: :unlocked},
                %Branch{
                  reply_type: {:tagged, :error, {:literal, :invalid_token}},
                  next_state: :locked
                }
              ],
              update: %{
                fun: fn _msg, reply, tracks ->
                  case reply do
                    :ok -> %{tracks | holder: nil}
                    _ -> tracks
                  end
                end,
                ast:
                  quote(
                    do: fn _msg, reply, tracks ->
                      case reply do
                        :ok -> %{tracks | holder: nil}
                        _ -> tracks
                      end
                    end
                  )
              }
            }
          ]
        },
        expired: %State{name: :expired, terminal: true}
      },
      anystate: [
        %Transition{
          message_pattern: :ping,
          message_types: [],
          kind: :call,
          branches: [%Branch{reply_type: {:literal, :pong}, next_state: :__same__}]
        }
      ],
      properties: [
        %Property{
          name: :monotonic_tokens,
          checks: [
            %Check{
              kind: :action,
              spec: %{
                fun: fn old, new -> new.fence_token >= old.fence_token end,
                ast: quote(do: fn old, new -> new.fence_token >= old.fence_token end)
              }
            }
          ]
        },
        %Property{
          name: :token_non_negative,
          checks: [
            %Check{
              kind: :invariant,
              spec: %{
                fun: fn tracks -> tracks.fence_token >= 0 end,
                ast: quote(do: fn tracks -> tracks.fence_token >= 0 end)
              }
            }
          ]
        }
      ]
    }
  end

  defp lock_config do
    %ModelConfig{
      domains: %{
        holder: {:model_values, [:c1, :c2]},
        fence_token: 0..5,
        pos_integer: 1..5
      },
      symmetry_sets: [:holder]
    }
  end

  # -- BuildStateSpace Tests --

  describe "BuildStateSpace" do
    test "produces variables for state and tracks" do
      {:ok, ss} = BuildStateSpace.run(lock_ir(), lock_config())

      var_names = Enum.map(ss.variables, & &1.name)
      assert "state" in var_names
      assert "holder" in var_names
      assert "fence_token" in var_names
    end

    test "state variable has correct type and init" do
      {:ok, ss} = BuildStateSpace.run(lock_ir(), lock_config())
      state_var = Enum.find(ss.variables, &(&1.name == "state"))

      assert state_var.init == ~s("unlocked")
      assert state_var.type =~ "unlocked"
      assert state_var.type =~ "locked"
      assert state_var.type =~ "expired"
    end

    test "track variables use config domains" do
      {:ok, ss} = BuildStateSpace.run(lock_ir(), lock_config())
      ft_var = Enum.find(ss.variables, &(&1.name == "fence_token"))

      assert ft_var.type == "0..5"
      assert ft_var.init == "0"
    end

    test "holder variable uses model values" do
      {:ok, ss} = BuildStateSpace.run(lock_ir(), lock_config())
      holder_var = Enum.find(ss.variables, &(&1.name == "holder"))

      assert holder_var.type == "{c1, c2}"
      assert holder_var.init == "NULL"
    end

    test "TypeInvariant contains all variables" do
      {:ok, ss} = BuildStateSpace.run(lock_ir(), lock_config())

      assert ss.type_invariant =~ "state \\in"
      assert ss.type_invariant =~ "holder \\in"
      assert ss.type_invariant =~ "fence_token \\in"
    end

    test "Init contains all initial values" do
      {:ok, ss} = BuildStateSpace.run(lock_ir(), lock_config())

      assert ss.init =~ ~s(state = "unlocked")
      assert ss.init =~ "fence_token = 0"
      assert ss.init =~ "holder = NULL"
    end

    test "no event variable when no local invariants" do
      {:ok, ss} = BuildStateSpace.run(lock_ir(), lock_config())
      refute ss.has_event_var
      refute Enum.any?(ss.variables, &(&1.name == "event"))
    end

    test "module name extracted from IR name" do
      {:ok, ss} = BuildStateSpace.run(lock_ir(), lock_config())
      assert ss.module_name == "Protocol"
    end
  end

  # -- BuildActions Tests --

  describe "BuildActions" do
    setup do
      ir = lock_ir()
      config = lock_config()
      {:ok, ss} = BuildStateSpace.run(ir, config)
      {:ok, actions} = BuildActions.run(ir, ss, config)
      %{ir: ir, ss: ss, config: config, actions: actions}
    end

    test "produces actions for all transitions", %{actions: actions} do
      names = Enum.map(actions, & &1.name)

      # Acquire from unlocked to locked.
      assert Enum.any?(names, &String.contains?(&1, "Acquire"))
      # Release from locked to unlocked.
      assert Enum.any?(names, &String.contains?(&1, "Release"))
      # Ping (anystate) in both non-terminal states.
      assert Enum.any?(names, &String.contains?(&1, "Ping"))
    end

    test "actions have state preconditions", %{actions: actions} do
      acquire = Enum.find(actions, &(&1.message_tag == "acquire"))
      assert ~s(state = "unlocked") in acquire.preconditions
    end

    test "actions have primed state assignments", %{actions: actions} do
      acquire = Enum.find(actions, &(&1.message_tag == "acquire"))
      assert acquire.primed["state"] == ~s("locked")
    end

    test "anystate ping preserves state", %{actions: actions} do
      pings = Enum.filter(actions, &(&1.message_tag == "ping"))
      assert length(pings) > 0

      Enum.each(pings, fn ping ->
        assert ping.source_state == ping.target_state
      end)
    end

    test "no actions for terminal states", %{actions: actions} do
      expired_actions =
        Enum.filter(actions, &(&1.source_state == "expired"))

      assert expired_actions == []
    end

    test "acquire has existential variables for params", %{actions: actions} do
      acquire = Enum.find(actions, &(&1.message_tag == "acquire"))

      var_names = Enum.map(acquire.existential_vars, fn {name, _} -> name end)
      assert Enum.any?(var_names, &String.contains?(&1, "msg_"))
    end

    test "UNCHANGED includes non-modified variables", %{actions: actions} do
      pings = Enum.filter(actions, &(&1.message_tag == "ping"))

      Enum.each(pings, fn ping ->
        # Ping doesn't modify tracks.
        assert "holder" in ping.unchanged
        assert "fence_token" in ping.unchanged
      end)
    end
  end

  # -- BuildProperties Tests --

  describe "BuildProperties" do
    test "produces invariant properties" do
      {:ok, props} = BuildProperties.run(lock_ir())

      invariant = Enum.find(props, &(&1.name == "TokenNonNegative"))
      assert invariant
      assert invariant.kind == :invariant
      assert invariant.formula =~ "fence_token >= 0"
    end

    test "produces action properties" do
      {:ok, props} = BuildProperties.run(lock_ir())

      action = Enum.find(props, &(&1.name == "MonotonicTokens"))
      assert action
      assert action.kind == :temporal
      assert action.formula =~ "fence_token >= fence_token"
    end

    test "bounded property" do
      ir = %IR{
        name: Test.Bounded,
        initial: :ready,
        states: %{ready: %State{name: :ready}},
        properties: [
          %Property{
            name: :counter_bounded,
            checks: [%Check{kind: :bounded, spec: %{track: :counter, max: 100}}]
          }
        ]
      }

      {:ok, props} = BuildProperties.run(ir)
      bounded = Enum.find(props, &(&1.name == "CounterBounded"))
      assert bounded.kind == :invariant
      assert bounded.formula =~ "counter =< 100"
    end

    test "liveness property" do
      ir = %IR{
        name: Test.Liveness,
        initial: :ready,
        states: %{ready: %State{name: :ready}},
        properties: [
          %Property{
            name: :no_starvation,
            checks: [
              %Check{
                kind: :liveness,
                spec: %{
                  trigger: {:in_state, :locked},
                  target: {:in_state, :unlocked},
                  fairness: :weak
                }
              }
            ]
          }
        ]
      }

      {:ok, props} = BuildProperties.run(ir)
      liveness = Enum.find(props, &(&1.name == "NoStarvation"))
      assert liveness.kind == :temporal
      assert liveness.formula =~ "~>"
      assert liveness.formula =~ "locked"
      assert liveness.formula =~ "unlocked"
    end
  end

  # -- Emit Tests --

  describe "Emit (via Compiler)" do
    test "produces valid TLA+ module structure" do
      {:ok, result} = Compiler.compile(lock_ir(), lock_config())

      assert result.tla =~ "---- MODULE Protocol ----"
      assert result.tla =~ "EXTENDS Integers, Sequences, TLC"
      assert result.tla =~ "VARIABLES"
      assert result.tla =~ "TypeInvariant =="
      assert result.tla =~ "Init =="
      assert result.tla =~ "Next =="
      assert result.tla =~ "Spec =="
      assert result.tla =~ "===="
    end

    test "produces valid CFG file" do
      {:ok, result} = Compiler.compile(lock_ir(), lock_config())

      assert result.cfg =~ "SPECIFICATION Spec"
      assert result.cfg =~ "INVARIANT TypeInvariant"
      assert result.cfg =~ "INVARIANT TokenNonNegative"
      assert result.cfg =~ "PROPERTY MonotonicTokens"
    end

    test "TLA+ contains all action definitions" do
      {:ok, result} = Compiler.compile(lock_ir(), lock_config())

      assert result.tla =~ "Acquire"
      assert result.tla =~ "Release"
      assert result.tla =~ "Ping"
    end

    test "TLA+ contains property definitions" do
      {:ok, result} = Compiler.compile(lock_ir(), lock_config())

      assert result.tla =~ "TokenNonNegative"
      assert result.tla =~ "MonotonicTokens"
    end

    test "NULL constant in cfg when track has nil default" do
      {:ok, result} = Compiler.compile(lock_ir(), lock_config())

      assert result.cfg =~ "CONSTANT NULL = NULL"
    end
  end

  # -- Full Pipeline Integration --

  describe "full pipeline" do
    test "compiles lock protocol end-to-end" do
      {:ok, result} = Compiler.compile(lock_ir(), lock_config())

      # Verify all components present.
      assert is_binary(result.tla)
      assert is_binary(result.cfg)
      assert length(result.actions) > 0
      assert length(result.properties) == 2
      assert result.state_space.module_name == "Protocol"
    end

    test "compiles minimal protocol" do
      ir = %IR{
        name: Minimal.Protocol,
        initial: :ready,
        states: %{
          ready: %State{
            name: :ready,
            transitions: [
              %Transition{
                message_pattern: :done,
                message_types: [],
                kind: :call,
                branches: [%Branch{reply_type: {:literal, :ok}, next_state: :finished}]
              }
            ]
          },
          finished: %State{name: :finished, terminal: true}
        }
      }

      {:ok, result} = Compiler.compile(ir, %ModelConfig{})

      assert result.tla =~ "MODULE Protocol"
      assert result.tla =~ "Done"
      assert length(result.actions) == 1
      assert result.properties == []
    end
  end
end
