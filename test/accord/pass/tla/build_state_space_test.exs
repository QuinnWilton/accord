defmodule Accord.Pass.TLA.BuildStateSpaceTest do
  use ExUnit.Case, async: true

  alias Accord.IR
  alias Accord.IR.{Branch, Check, Property, State, Track, Transition}
  alias Accord.Pass.TLA.BuildStateSpace
  alias Accord.TLA.ModelConfig

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

  defp default_config, do: %ModelConfig{}

  describe "variable collection" do
    test "always includes a state variable" do
      {:ok, ss} = BuildStateSpace.run(minimal_ir(), default_config())
      state_var = Enum.find(ss.variables, &(&1.name == "state"))

      assert state_var
      assert state_var.init == ~s("ready")
    end

    test "state type includes all declared states" do
      {:ok, ss} = BuildStateSpace.run(minimal_ir(), default_config())
      state_var = Enum.find(ss.variables, &(&1.name == "state"))

      assert state_var.type =~ "ready"
      assert state_var.type =~ "done"
    end

    test "includes one variable per track" do
      ir = %{
        minimal_ir()
        | tracks: [
            %Track{name: :counter, type: :integer, default: 0},
            %Track{name: :label, type: :atom, default: :none}
          ]
      }

      {:ok, ss} = BuildStateSpace.run(ir, default_config())
      var_names = Enum.map(ss.variables, & &1.name)

      assert "counter" in var_names
      assert "label" in var_names
    end

    test "track init uses default value" do
      ir = %{
        minimal_ir()
        | tracks: [
            %Track{name: :counter, type: :integer, default: 42}
          ]
      }

      {:ok, ss} = BuildStateSpace.run(ir, default_config())
      counter_var = Enum.find(ss.variables, &(&1.name == "counter"))

      assert counter_var.init == "42"
    end
  end

  describe "NULL constants" do
    test "track with nil default includes NULL in type" do
      ir = %{
        minimal_ir()
        | tracks: [
            %Track{name: :holder, type: :term, default: nil}
          ]
      }

      {:ok, ss} = BuildStateSpace.run(ir, default_config())
      holder_var = Enum.find(ss.variables, &(&1.name == "holder"))

      assert holder_var.type =~ "NULL"
      assert holder_var.init == "NULL"
    end

    test "track with non-nil default does not include NULL" do
      ir = %{
        minimal_ir()
        | tracks: [
            %Track{name: :counter, type: :integer, default: 0}
          ]
      }

      {:ok, ss} = BuildStateSpace.run(ir, %ModelConfig{domains: %{counter: 0..5}})
      counter_var = Enum.find(ss.variables, &(&1.name == "counter"))

      refute counter_var.type =~ "NULL"
    end

    test "NULL appears in constants when tracks have nil defaults" do
      ir = %{
        minimal_ir()
        | tracks: [
            %Track{name: :holder, type: :term, default: nil}
          ]
      }

      {:ok, ss} = BuildStateSpace.run(ir, default_config())

      assert "NULL" in ss.constants
    end
  end

  describe "model value constants" do
    test "collects model value names from track domains" do
      ir = %{
        minimal_ir()
        | tracks: [
            %Track{name: :color, type: :atom, default: :red}
          ]
      }

      config = %ModelConfig{domains: %{color: {:model_values, [:red, :blue]}}}
      {:ok, ss} = BuildStateSpace.run(ir, config)

      assert "red" in ss.constants
      assert "blue" in ss.constants
    end

    test "collects numbered model values" do
      ir = %{
        minimal_ir()
        | tracks: [
            %Track{name: :item, type: :term, default: :x}
          ]
      }

      config = %ModelConfig{domains: %{item: {:model_values, 2}}}
      {:ok, ss} = BuildStateSpace.run(ir, config)

      assert "mv1" in ss.constants
      assert "mv2" in ss.constants
    end

    test "no constants for range domains" do
      ir = %{
        minimal_ir()
        | tracks: [
            %Track{name: :counter, type: :integer, default: 0}
          ]
      }

      config = %ModelConfig{domains: %{counter: 0..10}}
      {:ok, ss} = BuildStateSpace.run(ir, config)

      assert ss.constants == []
    end
  end

  describe "event variable" do
    test "not present without local invariants" do
      {:ok, ss} = BuildStateSpace.run(minimal_ir(), default_config())

      refute ss.has_event_var
      refute Enum.any?(ss.variables, &(&1.name == "event"))
    end

    test "present when IR has local invariants" do
      ir = %{
        minimal_ir()
        | properties: [
            %Property{
              name: :state_check,
              checks: [
                %Check{
                  kind: :local_invariant,
                  spec: %{state: :ready, fun: fn _, _ -> true end, ast: nil}
                }
              ]
            }
          ]
      }

      {:ok, ss} = BuildStateSpace.run(ir, default_config())

      assert ss.has_event_var
      event_var = Enum.find(ss.variables, &(&1.name == "event"))
      assert event_var
      assert event_var.init == ~s("none")
      assert event_var.type == "STRING"
    end
  end

  describe "correspondence counter variables" do
    test "generates counter var for correspondence checks" do
      ir = %{
        minimal_ir()
        | properties: [
            %Property{
              name: :open_close,
              checks: [
                %Check{kind: :correspondence, spec: %{open: :open, close: [:close]}}
              ]
            }
          ]
      }

      {:ok, ss} = BuildStateSpace.run(ir, default_config())

      assert length(ss.correspondences) == 1
      [corr] = ss.correspondences
      assert corr.open == :open
      assert corr.close == [:close]
      assert corr.counter_var == "open_pending"

      counter_var = Enum.find(ss.variables, &(&1.name == "open_pending"))
      assert counter_var
      assert counter_var.init == "0"
    end
  end

  describe "TypeInvariant and Init" do
    test "TypeInvariant references all variables" do
      ir = %{
        minimal_ir()
        | tracks: [
            %Track{name: :x, type: :integer, default: 0}
          ]
      }

      {:ok, ss} = BuildStateSpace.run(ir, %ModelConfig{domains: %{x: 0..5}})

      assert ss.type_invariant =~ "state \\in"
      assert ss.type_invariant =~ "x \\in 0..5"
    end

    test "Init assigns all initial values" do
      ir = %{
        minimal_ir()
        | tracks: [
            %Track{name: :x, type: :integer, default: 7}
          ]
      }

      {:ok, ss} = BuildStateSpace.run(ir, default_config())

      assert ss.init =~ ~s(state = "ready")
      assert ss.init =~ "x = 7"
    end
  end
end
