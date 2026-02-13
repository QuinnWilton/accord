defmodule Accord.Pass.TLA.EmitTest do
  use ExUnit.Case, async: true

  alias Accord.Pass.TLA.Emit
  alias Accord.TLA.{Action, Property, StateSpace}

  defp minimal_state_space do
    %StateSpace{
      module_name: "TestModule",
      variables: [
        %{name: "state", type: ~s({"ready", "done"}), init: ~s("ready")},
        %{name: "counter", type: "0..10", init: "0"}
      ],
      type_invariant:
        ~s(TypeInvariant == \n    /\\ state \\in {"ready", "done"}\n    /\\ counter \\in 0..10),
      init: ~s(Init == \n    /\\ state = "ready"\n    /\\ counter = 0),
      states: ["ready", "done"],
      constants: []
    }
  end

  defp sample_action do
    %Action{
      name: "GoFromReadyToDone",
      source_state: "ready",
      target_state: "done",
      message_tag: "go",
      preconditions: [~s(state = "ready")],
      existential_vars: [],
      primed: %{"state" => ~s("done")},
      unchanged: ["counter"],
      comment: "go from ready to done"
    }
  end

  describe "MODULE header" do
    test "includes module name" do
      {:ok, %{tla: tla}} = Emit.run(minimal_state_space(), [sample_action()], [])

      assert tla =~ "---- MODULE TestModule ----"
    end

    test "includes EXTENDS" do
      {:ok, %{tla: tla}} = Emit.run(minimal_state_space(), [sample_action()], [])

      assert tla =~ "EXTENDS Integers, Sequences, TLC"
    end

    test "ends with ====" do
      {:ok, %{tla: tla}} = Emit.run(minimal_state_space(), [sample_action()], [])

      assert tla =~ "===="
    end
  end

  describe "VARIABLES" do
    test "declares all variables" do
      {:ok, %{tla: tla}} = Emit.run(minimal_state_space(), [sample_action()], [])

      assert tla =~ "VARIABLES state, counter"
    end

    test "includes vars tuple" do
      {:ok, %{tla: tla}} = Emit.run(minimal_state_space(), [sample_action()], [])

      assert tla =~ "vars == <<state, counter>>"
    end
  end

  describe "CONSTANTS" do
    test "included when state space has constants" do
      ss = %{minimal_state_space() | constants: ["NULL", "mv1", "mv2"]}
      {:ok, %{tla: tla}} = Emit.run(ss, [sample_action()], [])

      assert tla =~ "CONSTANTS NULL, mv1, mv2"
    end

    test "omitted when no constants" do
      {:ok, %{tla: tla}} = Emit.run(minimal_state_space(), [sample_action()], [])

      refute tla =~ "CONSTANTS"
    end
  end

  describe "TypeInvariant" do
    test "rendered in TLA+ output" do
      {:ok, %{tla: tla}} = Emit.run(minimal_state_space(), [sample_action()], [])

      assert tla =~ "TypeInvariant =="
    end
  end

  describe "Init" do
    test "rendered in TLA+ output" do
      {:ok, %{tla: tla}} = Emit.run(minimal_state_space(), [sample_action()], [])

      assert tla =~ "Init =="
    end
  end

  describe "actions without existentials" do
    test "renders action definition" do
      {:ok, %{tla: tla}} = Emit.run(minimal_state_space(), [sample_action()], [])

      assert tla =~ "GoFromReadyToDone =="
      assert tla =~ ~s(/\\ state = "ready")
      assert tla =~ ~s(/\\ state' = "done")
      assert tla =~ "/\\ UNCHANGED counter"
    end

    test "renders action comment" do
      {:ok, %{tla: tla}} = Emit.run(minimal_state_space(), [sample_action()], [])

      assert tla =~ "\\* go from ready to done"
    end
  end

  describe "actions with existentials" do
    test "renders existential quantification" do
      action = %Action{
        name: "SetFromReadyToReady",
        source_state: "ready",
        target_state: "ready",
        message_tag: "set",
        preconditions: [~s(state = "ready")],
        existential_vars: [{"msg_val", "0..10"}],
        primed: %{"state" => ~s("ready"), "counter" => "msg_val"},
        unchanged: [],
        comment: nil
      }

      {:ok, %{tla: tla}} = Emit.run(minimal_state_space(), [action], [])

      assert tla =~ "\\E msg_val \\in 0..10 :"
    end

    test "multiple existential vars joined with commas" do
      action = %Action{
        name: "MoveFromReadyToReady",
        source_state: "ready",
        target_state: "ready",
        message_tag: "move",
        preconditions: [~s(state = "ready")],
        existential_vars: [{"msg_x", "0..5"}, {"msg_y", "0..5"}],
        primed: %{"state" => ~s("ready")},
        unchanged: ["counter"],
        comment: nil
      }

      {:ok, %{tla: tla}} = Emit.run(minimal_state_space(), [action], [])

      assert tla =~ "\\E msg_x \\in 0..5, msg_y \\in 0..5 :"
    end
  end

  describe "Next" do
    test "disjunction of all actions" do
      action2 = %Action{
        name: "PingFromReadyToReady",
        source_state: "ready",
        target_state: "ready",
        message_tag: "ping",
        preconditions: [~s(state = "ready")],
        primed: %{"state" => ~s("ready")},
        unchanged: ["counter"],
        comment: nil
      }

      {:ok, %{tla: tla}} = Emit.run(minimal_state_space(), [sample_action(), action2], [])

      assert tla =~ "Next =="
      assert tla =~ "\\/ GoFromReadyToDone"
      assert tla =~ "\\/ PingFromReadyToReady"
    end

    test "FALSE when no actions" do
      {:ok, %{tla: tla}} = Emit.run(minimal_state_space(), [], [])

      assert tla =~ "Next == FALSE"
    end
  end

  describe "Spec" do
    test "includes Init and Next" do
      {:ok, %{tla: tla}} = Emit.run(minimal_state_space(), [sample_action()], [])

      assert tla =~ "Spec == Init /\\ [][Next]_vars"
    end
  end

  describe "properties in TLA+" do
    test "renders property formulas" do
      prop = %Property{
        name: "CounterBounded",
        kind: :invariant,
        formula: "CounterBounded == counter =< 100",
        comment: "bounded: counter_bounded"
      }

      {:ok, %{tla: tla}} = Emit.run(minimal_state_space(), [sample_action()], [prop])

      assert tla =~ "CounterBounded == counter =< 100"
      assert tla =~ "\\* bounded: counter_bounded"
    end

    test "no properties section when empty" do
      {:ok, %{tla: tla}} = Emit.run(minimal_state_space(), [sample_action()], [])

      # Should not have a dangling "Properties" section.
      refute tla =~ "\\* Properties"
    end
  end

  describe "CFG generation" do
    test "includes SPECIFICATION" do
      {:ok, %{cfg: cfg}} = Emit.run(minimal_state_space(), [sample_action()], [])

      assert cfg =~ "SPECIFICATION Spec"
    end

    test "includes TypeInvariant" do
      {:ok, %{cfg: cfg}} = Emit.run(minimal_state_space(), [sample_action()], [])

      assert cfg =~ "INVARIANT TypeInvariant"
    end

    test "includes invariant properties" do
      prop = %Property{
        name: "CounterBounded",
        kind: :invariant,
        formula: "CounterBounded == counter =< 100",
        comment: nil
      }

      {:ok, %{cfg: cfg}} = Emit.run(minimal_state_space(), [sample_action()], [prop])

      assert cfg =~ "INVARIANT CounterBounded"
    end

    test "includes temporal properties as PROPERTY" do
      prop = %Property{
        name: "Monotonic",
        kind: :temporal,
        formula: "Monotonic == [][counter' >= counter]_<<counter>>",
        comment: nil
      }

      {:ok, %{cfg: cfg}} = Emit.run(minimal_state_space(), [sample_action()], [prop])

      assert cfg =~ "PROPERTY Monotonic"
    end

    test "includes CONSTANT declarations for model values" do
      ss = %{minimal_state_space() | constants: ["NULL", "mv1"]}
      {:ok, %{cfg: cfg}} = Emit.run(ss, [sample_action()], [])

      assert cfg =~ "CONSTANT NULL = NULL"
      assert cfg =~ "CONSTANT mv1 = mv1"
    end
  end
end
