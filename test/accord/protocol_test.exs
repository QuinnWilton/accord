defmodule Accord.ProtocolTest do
  use ExUnit.Case, async: true

  alias Accord.IR
  alias Accord.IR.{Branch, State, Transition}

  # -- Test protocol fixtures defined inline --

  defmodule SimpleProtocol do
    use Accord.Protocol

    initial(:ready)

    state :ready do
      on(:ping, reply: :pong, goto: :ready)
      on(:stop, reply: :stopped, goto: :stopped)
    end

    state(:stopped, terminal: true)
  end

  defmodule TypedProtocol do
    use Accord.Protocol

    initial(:ready)

    state :ready do
      on({:increment, _amount :: pos_integer()}, reply: {:ok, integer()}, goto: :ready)
      on({:get, _key :: atom()}, reply: term(), goto: :ready)
      on(:stop, reply: :stopped, goto: :stopped)
    end

    state(:stopped, terminal: true)
  end

  defmodule AnystateProtocol do
    use Accord.Protocol

    initial(:ready)

    state :ready do
      on(:stop, reply: :stopped, goto: :stopped)
    end

    state(:stopped, terminal: true)

    anystate do
      on(:ping, reply: :pong)
      cast(:heartbeat)
    end
  end

  defmodule MultiStateProtocol do
    use Accord.Protocol

    initial(:idle)

    state :idle do
      on(:start, reply: :ok, goto: :running)
    end

    state :running do
      on(:pause, reply: :ok, goto: :paused)
      on(:stop, reply: :ok, goto: :done)
    end

    state :paused do
      on(:resume, reply: :ok, goto: :running)
      on(:stop, reply: :ok, goto: :done)
    end

    state(:done, terminal: true)
  end

  describe "__ir__/0 — basic structure" do
    test "returns an IR struct with correct module name" do
      ir = SimpleProtocol.__ir__()
      assert %IR{} = ir
      assert ir.name == SimpleProtocol
    end

    test "sets initial state" do
      assert SimpleProtocol.__ir__().initial == :ready
    end

    test "captures source file" do
      ir = SimpleProtocol.__ir__()
      assert is_binary(ir.source_file)
      assert ir.source_file =~ "protocol_test.exs"
    end
  end

  describe "__ir__/0 — states" do
    test "includes declared states" do
      ir = SimpleProtocol.__ir__()
      assert Map.has_key?(ir.states, :ready)
      assert Map.has_key?(ir.states, :stopped)
    end

    test "non-terminal state has transitions" do
      ir = SimpleProtocol.__ir__()
      ready = ir.states[:ready]
      assert %State{} = ready
      assert ready.terminal == false
      assert length(ready.transitions) == 2
    end

    test "terminal state has no transitions" do
      ir = SimpleProtocol.__ir__()
      stopped = ir.states[:stopped]
      assert stopped.terminal == true
      assert stopped.transitions == []
    end

    test "state has span" do
      ir = SimpleProtocol.__ir__()
      ready = ir.states[:ready]
      assert %Pentiment.Span.Position{} = ready.span
      assert ready.span.start_line > 0
    end
  end

  describe "__ir__/0 — simple transitions" do
    test "atom message produces atom pattern with no types" do
      ir = SimpleProtocol.__ir__()
      [ping, _stop] = ir.states[:ready].transitions

      assert %Transition{} = ping
      assert ping.message_pattern == :ping
      assert ping.message_types == []
      assert ping.kind == :call
    end

    test "transition has branch with reply type and next state" do
      ir = SimpleProtocol.__ir__()
      [ping, stop] = ir.states[:ready].transitions

      assert [%Branch{reply_type: {:literal, :pong}, next_state: :ready}] = ping.branches
      assert [%Branch{reply_type: {:literal, :stopped}, next_state: :stopped}] = stop.branches
    end

    test "transition has span" do
      ir = SimpleProtocol.__ir__()
      [ping, _] = ir.states[:ready].transitions
      assert %Pentiment.Span.Position{} = ping.span
    end
  end

  describe "__ir__/0 — typed messages" do
    test "typed tuple message produces wildcard pattern and types" do
      ir = TypedProtocol.__ir__()
      [increment, get, _stop] = ir.states[:ready].transitions

      assert increment.message_pattern == {:increment, :_}
      assert increment.message_types == [:pos_integer]

      assert get.message_pattern == {:get, :_}
      assert get.message_types == [:atom]
    end

    test "tagged reply type is parsed correctly" do
      ir = TypedProtocol.__ir__()
      [increment, _, _] = ir.states[:ready].transitions

      assert [%Branch{reply_type: {:tagged, :ok, :integer}}] = increment.branches
    end

    test "term reply type is parsed correctly" do
      ir = TypedProtocol.__ir__()
      [_, get, _] = ir.states[:ready].transitions

      assert [%Branch{reply_type: :term}] = get.branches
    end
  end

  describe "__ir__/0 — anystate" do
    test "anystate transitions are in the anystate list" do
      ir = AnystateProtocol.__ir__()
      assert length(ir.anystate) == 2
    end

    test "anystate on produces :call transition with :__same__ next state" do
      ir = AnystateProtocol.__ir__()
      [ping, _heartbeat] = ir.anystate

      assert ping.kind == :call
      assert ping.message_pattern == :ping
      assert [%Branch{reply_type: {:literal, :pong}, next_state: :__same__}] = ping.branches
    end

    test "anystate cast produces :cast transition with no branches" do
      ir = AnystateProtocol.__ir__()
      [_ping, heartbeat] = ir.anystate

      assert heartbeat.kind == :cast
      assert heartbeat.message_pattern == :heartbeat
      assert heartbeat.branches == []
    end
  end

  describe "__ir__/0 — multi-state" do
    test "all states are present" do
      ir = MultiStateProtocol.__ir__()
      assert map_size(ir.states) == 4
      assert Map.has_key?(ir.states, :idle)
      assert Map.has_key?(ir.states, :running)
      assert Map.has_key?(ir.states, :paused)
      assert Map.has_key?(ir.states, :done)
    end

    test "each state has correct transition count" do
      ir = MultiStateProtocol.__ir__()
      assert length(ir.states[:idle].transitions) == 1
      assert length(ir.states[:running].transitions) == 2
      assert length(ir.states[:paused].transitions) == 2
      assert length(ir.states[:done].transitions) == 0
    end
  end

  describe "compile-time errors" do
    test "missing initial state raises CompileError" do
      assert_raise CompileError, ~r/must declare `initial :state`/, fn ->
        defmodule BadNoInitial do
          use Accord.Protocol
          state(:ready, terminal: true)
        end
      end
    end

    test "anystate with goto raises CompileError" do
      assert_raise CompileError, ~r/anystate transitions cannot specify goto/, fn ->
        defmodule BadAnystateGoto do
          use Accord.Protocol

          initial(:ready)
          state(:ready, terminal: true)

          anystate do
            on(:ping, reply: :pong, goto: :ready)
          end
        end
      end
    end

    test "state transition without goto raises CompileError" do
      assert_raise CompileError, ~r/state transitions must specify goto/, fn ->
        defmodule BadNoGoto do
          use Accord.Protocol

          initial(:ready)

          state :ready do
            on(:ping, reply: :pong)
          end
        end
      end
    end
  end
end
