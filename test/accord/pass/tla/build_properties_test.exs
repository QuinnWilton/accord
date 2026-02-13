defmodule Accord.Pass.TLA.BuildPropertiesTest do
  use ExUnit.Case, async: true

  alias Accord.IR
  alias Accord.IR.{Check, Property, State, Track}
  alias Accord.Pass.TLA.BuildProperties

  defp base_ir(properties) do
    %IR{
      name: Test.Protocol,
      initial: :ready,
      states: %{ready: %State{name: :ready}},
      tracks: [%Track{name: :counter, type: :integer, default: 0}],
      properties: properties
    }
  end

  describe "invariant" do
    test "global invariant becomes TLA+ invariant" do
      ir =
        base_ir([
          %Property{
            name: :counter_positive,
            checks: [
              %Check{
                kind: :invariant,
                spec: %{
                  fun: fn tracks -> tracks.counter >= 0 end,
                  ast: quote(do: fn tracks -> tracks.counter >= 0 end)
                }
              }
            ]
          }
        ])

      {:ok, props} = BuildProperties.run(ir)
      [prop] = props

      assert prop.name == "CounterPositive"
      assert prop.kind == :invariant
      assert prop.formula =~ "counter >= 0"
    end

    test "invariant without AST produces TRUE" do
      ir =
        base_ir([
          %Property{
            name: :always_true,
            checks: [
              %Check{kind: :invariant, spec: %{fun: fn _ -> true end, ast: nil}}
            ]
          }
        ])

      {:ok, props} = BuildProperties.run(ir)
      [prop] = props

      assert prop.formula =~ "TRUE"
    end
  end

  describe "local_invariant" do
    test "produces state-conditioned invariant" do
      ir =
        base_ir([
          %Property{
            name: :ready_check,
            checks: [
              %Check{
                kind: :local_invariant,
                spec: %{
                  state: :ready,
                  fun: fn _, tracks -> tracks.counter >= 0 end,
                  ast: quote(do: fn _msg, tracks -> tracks.counter >= 0 end)
                }
              }
            ]
          }
        ])

      {:ok, props} = BuildProperties.run(ir)
      [prop] = props

      assert prop.name == "ReadyCheckReady"
      assert prop.kind == :invariant
      assert prop.formula =~ ~s(state = "ready")
      assert prop.formula =~ "=>"
    end
  end

  describe "action_property" do
    test "produces temporal action property" do
      ir =
        base_ir([
          %Property{
            name: :monotonic,
            checks: [
              %Check{
                kind: :action,
                spec: %{
                  fun: fn old, new -> new.counter >= old.counter end,
                  ast: quote(do: fn old, new -> new.counter >= old.counter end)
                }
              }
            ]
          }
        ])

      {:ok, props} = BuildProperties.run(ir)
      [prop] = props

      assert prop.name == "Monotonic"
      assert prop.kind == :temporal
      assert prop.formula =~ "counter' >= counter"
      assert prop.formula =~ "[]"
    end
  end

  describe "liveness" do
    test "produces leads-to formula" do
      ir =
        base_ir([
          %Property{
            name: :progress,
            checks: [
              %Check{
                kind: :liveness,
                spec: %{
                  trigger: {:in_state, :waiting},
                  target: {:in_state, :done},
                  fairness: :weak
                }
              }
            ]
          }
        ])

      {:ok, props} = BuildProperties.run(ir)
      [prop] = props

      assert prop.name == "Progress"
      assert prop.kind == :temporal
      assert prop.formula =~ "~>"
      assert prop.formula =~ ~s(state = "waiting")
      assert prop.formula =~ ~s(state = "done")
    end
  end

  describe "bounded" do
    test "produces bounded invariant" do
      ir =
        base_ir([
          %Property{
            name: :counter_bounded,
            checks: [%Check{kind: :bounded, spec: %{track: :counter, max: 50}}]
          }
        ])

      {:ok, props} = BuildProperties.run(ir)
      [prop] = props

      assert prop.name == "CounterBounded"
      assert prop.kind == :invariant
      assert prop.formula =~ "counter =< 50"
    end
  end

  describe "correspondence" do
    test "produces counter invariant" do
      ir =
        base_ir([
          %Property{
            name: :open_close,
            checks: [
              %Check{kind: :correspondence, spec: %{open: :open, close: [:close]}}
            ]
          }
        ])

      {:ok, props} = BuildProperties.run(ir)
      [prop] = props

      assert prop.name == "OpenClose"
      assert prop.kind == :invariant
      assert prop.formula =~ "open_pending >= 0"
    end
  end

  describe "forbidden" do
    test "produces negated invariant" do
      ir =
        base_ir([
          %Property{
            name: :no_negative,
            checks: [
              %Check{
                kind: :forbidden,
                spec: %{
                  fun: fn tracks -> tracks.counter < 0 end,
                  ast: quote(do: fn tracks -> tracks.counter < 0 end)
                }
              }
            ]
          }
        ])

      {:ok, props} = BuildProperties.run(ir)
      [prop] = props

      assert prop.name == "NoNegative"
      assert prop.kind == :invariant
      assert prop.formula =~ "~("
    end
  end

  describe "reachable" do
    test "produces auxiliary property" do
      ir =
        base_ir([
          %Property{
            name: :target_reachable,
            checks: [%Check{kind: :reachable, spec: %{target: :done}}]
          }
        ])

      {:ok, props} = BuildProperties.run(ir)
      [prop] = props

      assert prop.name == "TargetReachable"
      assert prop.kind == :auxiliary
      assert prop.formula =~ "reachable"
    end
  end

  describe "multiple checks in one property" do
    test "each check produces a separate TLA+ property" do
      ir =
        base_ir([
          %Property{
            name: :multi,
            checks: [
              %Check{kind: :bounded, spec: %{track: :counter, max: 100}},
              %Check{
                kind: :invariant,
                spec: %{
                  fun: fn tracks -> tracks.counter >= 0 end,
                  ast: quote(do: fn tracks -> tracks.counter >= 0 end)
                }
              }
            ]
          }
        ])

      {:ok, props} = BuildProperties.run(ir)

      assert length(props) == 2
      kinds = Enum.map(props, & &1.kind)
      assert :invariant in kinds
    end
  end
end
