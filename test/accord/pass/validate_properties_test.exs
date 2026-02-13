defmodule Accord.Pass.ValidatePropertiesTest do
  use ExUnit.Case, async: true

  alias Accord.IR
  alias Accord.IR.{Branch, Check, Property, State, Track, Transition}
  alias Accord.Pass.ValidateProperties

  defp base_ir do
    %IR{
      name: Test,
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
              message_pattern: {:acquire, :_, :_},
              message_types: [:term, :pos_integer],
              kind: :call,
              branches: [
                %Branch{reply_type: {:tagged, :ok, :pos_integer}, next_state: :locked}
              ]
            }
          ]
        },
        locked: %State{
          name: :locked,
          transitions: [
            %Transition{
              message_pattern: {:release, :_},
              message_types: [:term],
              kind: :call,
              branches: [
                %Branch{reply_type: {:literal, :ok}, next_state: :unlocked}
              ]
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
          branches: [
            %Branch{reply_type: {:literal, :pong}, next_state: :__same__}
          ]
        }
      ],
      properties: []
    }
  end

  test "accepts IR with no properties" do
    assert {:ok, _} = ValidateProperties.run(base_ir())
  end

  test "accepts valid bounded check" do
    ir = %{
      base_ir()
      | properties: [
          %Property{
            name: :fence_token_bounded,
            checks: [
              %Check{kind: :bounded, spec: %{track: :fence_token, max: 1000}}
            ]
          }
        ]
    }

    assert {:ok, _} = ValidateProperties.run(ir)
  end

  test "rejects bounded check with nonexistent track" do
    ir = %{
      base_ir()
      | properties: [
          %Property{
            name: :bad_bounded,
            checks: [
              %Check{kind: :bounded, spec: %{track: :nonexistent, max: 1000}}
            ]
          }
        ]
    }

    assert {:error, [report]} = ValidateProperties.run(ir)
    assert report.message =~ "nonexistent"
  end

  test "accepts valid local_invariant check" do
    ir = %{
      base_ir()
      | properties: [
          %Property{
            name: :locked_invariant,
            checks: [
              %Check{
                kind: :local_invariant,
                spec: %{state: :locked, fun: fn _msg, _tracks -> true end}
              }
            ]
          }
        ]
    }

    assert {:ok, _} = ValidateProperties.run(ir)
  end

  test "rejects local_invariant with nonexistent state" do
    ir = %{
      base_ir()
      | properties: [
          %Property{
            name: :bad_invariant,
            checks: [
              %Check{
                kind: :local_invariant,
                spec: %{state: :nonexistent, fun: fn _msg, _tracks -> true end}
              }
            ]
          }
        ]
    }

    assert {:error, [report]} = ValidateProperties.run(ir)
    assert report.message =~ "nonexistent"
  end

  test "accepts valid reachable check" do
    ir = %{
      base_ir()
      | properties: [
          %Property{
            name: :locked_reachable,
            checks: [
              %Check{kind: :reachable, spec: %{target: :locked}}
            ]
          }
        ]
    }

    assert {:ok, _} = ValidateProperties.run(ir)
  end

  test "rejects reachable with nonexistent state" do
    ir = %{
      base_ir()
      | properties: [
          %Property{
            name: :bad_reachable,
            checks: [
              %Check{kind: :reachable, spec: %{target: :nonexistent}}
            ]
          }
        ]
    }

    assert {:error, [report]} = ValidateProperties.run(ir)
    assert report.message =~ "nonexistent"
  end

  test "accepts valid precedence check" do
    ir = %{
      base_ir()
      | properties: [
          %Property{
            name: :lock_precedence,
            checks: [
              %Check{kind: :precedence, spec: %{target: :locked, required: :unlocked}}
            ]
          }
        ]
    }

    assert {:ok, _} = ValidateProperties.run(ir)
  end

  test "rejects precedence with nonexistent target" do
    ir = %{
      base_ir()
      | properties: [
          %Property{
            name: :bad_precedence,
            checks: [
              %Check{kind: :precedence, spec: %{target: :nonexistent, required: :unlocked}}
            ]
          }
        ]
    }

    assert {:error, [report]} = ValidateProperties.run(ir)
    assert report.message =~ "nonexistent"
  end

  test "accepts valid correspondence check" do
    ir = %{
      base_ir()
      | properties: [
          %Property{
            name: :acquire_release,
            checks: [
              %Check{
                kind: :correspondence,
                spec: %{open: :acquire, close: [:release]}
              }
            ]
          }
        ]
    }

    assert {:ok, _} = ValidateProperties.run(ir)
  end

  test "rejects correspondence with nonexistent open event" do
    ir = %{
      base_ir()
      | properties: [
          %Property{
            name: :bad_correspondence,
            checks: [
              %Check{
                kind: :correspondence,
                spec: %{open: :nonexistent, close: [:release]}
              }
            ]
          }
        ]
    }

    assert {:error, [report]} = ValidateProperties.run(ir)
    assert report.message =~ "nonexistent"
  end

  test "collects multiple errors" do
    ir = %{
      base_ir()
      | properties: [
          %Property{
            name: :bad_bounded,
            checks: [
              %Check{kind: :bounded, spec: %{track: :nonexistent, max: 100}}
            ]
          },
          %Property{
            name: :bad_reachable,
            checks: [
              %Check{kind: :reachable, spec: %{target: :nonexistent}}
            ]
          }
        ]
    }

    assert {:error, errors} = ValidateProperties.run(ir)
    assert length(errors) >= 2
  end
end
