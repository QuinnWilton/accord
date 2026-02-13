defmodule Accord.TLA.SpanMapTest do
  use ExUnit.Case, async: true

  alias Accord.IR
  alias Accord.IR.{Branch, Check, Property, State, Track, Transition}
  alias Accord.Pass.TLA.{BuildActions, BuildStateSpace}
  alias Accord.TLA.{ModelConfig, SpanMap}

  # Fixture with explicit spans on every node.
  defp lock_ir do
    %IR{
      name: Lock.Protocol,
      initial: :unlocked,
      tracks: [
        %Track{
          name: :holder,
          type: :term,
          default: nil,
          span: Pentiment.Span.position(8, 9)
        },
        %Track{
          name: :fence_token,
          type: :non_neg_integer,
          default: 0,
          span: Pentiment.Span.position(9, 9)
        }
      ],
      states: %{
        unlocked: %State{
          name: :unlocked,
          span: Pentiment.Span.position(11, 3),
          transitions: [
            %Transition{
              message_pattern: {:acquire, :_, :_},
              message_types: [:term, :pos_integer],
              kind: :call,
              branches: [
                %Branch{reply_type: {:tagged, :ok, :pos_integer}, next_state: :locked}
              ],
              guard: %{
                fun: fn {:acquire, _cid, token}, tracks -> token > tracks.fence_token end,
                ast:
                  quote(do: fn {:acquire, _cid, token}, tracks -> token > tracks.fence_token end)
              },
              update: %{
                fun: fn {:acquire, cid, token}, _reply, tracks ->
                  %{tracks | holder: cid, fence_token: token}
                end,
                ast:
                  quote(
                    do: fn {:acquire, cid, token}, _reply, tracks ->
                      %{tracks | holder: cid, fence_token: token}
                    end
                  )
              },
              span: Pentiment.Span.position(12, 5)
            }
          ]
        },
        locked: %State{
          name: :locked,
          span: Pentiment.Span.position(20, 3),
          transitions: [
            %Transition{
              message_pattern: {:release, :_, :_},
              message_types: [:term, :pos_integer],
              kind: :call,
              branches: [
                %Branch{reply_type: {:literal, :ok}, next_state: :unlocked}
              ],
              guard: %{
                fun: fn {:release, cid, token}, tracks ->
                  cid == tracks.holder and token == tracks.fence_token
                end,
                ast:
                  quote(
                    do: fn {:release, cid, token}, tracks ->
                      cid == tracks.holder and token == tracks.fence_token
                    end
                  )
              },
              update: %{
                fun: fn _msg, _reply, tracks -> %{tracks | holder: nil} end,
                ast: quote(do: fn _msg, _reply, tracks -> %{tracks | holder: nil} end)
              },
              span: Pentiment.Span.position(21, 5)
            }
          ]
        },
        expired: %State{
          name: :expired,
          terminal: true,
          span: Pentiment.Span.position(30, 3)
        }
      },
      anystate: [
        %Transition{
          message_pattern: :ping,
          message_types: [],
          kind: :call,
          branches: [%Branch{reply_type: {:literal, :pong}, next_state: :__same__}],
          span: Pentiment.Span.position(32, 5)
        }
      ],
      properties: [
        %Property{
          name: :monotonic_tokens,
          span: Pentiment.Span.position(35, 3),
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
          span: Pentiment.Span.position(39, 3),
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

  defp build_span_map do
    ir = lock_ir()
    config = lock_config()
    {:ok, ss} = BuildStateSpace.run(ir, config)
    {:ok, actions} = BuildActions.run(ir, ss, config)
    SpanMap.build(ir, actions)
  end

  describe "state spans" do
    test "maps state name strings to state declaration spans" do
      span_map = build_span_map()

      assert span_map["unlocked"] == Pentiment.Span.position(11, 3)
      assert span_map["locked"] == Pentiment.Span.position(20, 3)
      assert span_map["expired"] == Pentiment.Span.position(30, 3)
    end
  end

  describe "variable spans" do
    test "maps track names to track declaration spans" do
      span_map = build_span_map()

      assert span_map["holder"] == Pentiment.Span.position(8, 9)
      assert span_map["fence_token"] == Pentiment.Span.position(9, 9)
    end

    test "state variable has no span (it is implicit)" do
      span_map = build_span_map()

      refute Map.has_key?(span_map, "state")
    end
  end

  describe "property spans" do
    test "maps CamelCase property names to property declaration spans" do
      span_map = build_span_map()

      assert span_map["MonotonicTokens"] == Pentiment.Span.position(35, 3)
      assert span_map["TokenNonNegative"] == Pentiment.Span.position(39, 3)
    end
  end

  describe "action spans" do
    test "maps action names to originating transition spans" do
      span_map = build_span_map()

      # Acquire from unlocked → locked.
      acquire = Enum.find(Map.keys(span_map), &String.contains?(&1, "Acquire"))
      assert acquire
      assert span_map[acquire] == Pentiment.Span.position(12, 5)

      # Release from locked → unlocked.
      release = Enum.find(Map.keys(span_map), &String.contains?(&1, "Release"))
      assert release
      assert span_map[release] == Pentiment.Span.position(21, 5)
    end

    test "anystate actions map to the anystate transition span" do
      span_map = build_span_map()

      # Ping is an anystate transition — mapped to both unlocked and locked.
      ping_actions =
        span_map
        |> Enum.filter(fn {k, _v} -> String.contains?(k, "Ping") end)

      assert length(ping_actions) >= 2

      # All ping actions point to the same anystate transition span.
      Enum.each(ping_actions, fn {_name, span} ->
        assert span == Pentiment.Span.position(32, 5)
      end)
    end

    test "no actions for terminal states" do
      span_map = build_span_map()

      # "expired" may appear as a state span but not as an action source.
      expired_action_names =
        Enum.filter(Map.keys(span_map), fn k ->
          String.contains?(k, "FromExpired")
        end)

      assert expired_action_names == []
    end
  end

  describe "missing spans" do
    test "IR nodes without spans are excluded from the map" do
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
                branches: [
                  %Branch{reply_type: {:literal, :ok}, next_state: :finished}
                ]
                # No span.
              }
            ]
            # No span.
          },
          finished: %State{name: :finished, terminal: true}
        }
      }

      {:ok, ss} = BuildStateSpace.run(ir, %ModelConfig{})
      {:ok, actions} = BuildActions.run(ir, ss, %ModelConfig{})
      span_map = SpanMap.build(ir, actions)

      # No spans in the IR — map should be empty.
      assert span_map == %{}
    end
  end
end
