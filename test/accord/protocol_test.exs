defmodule Accord.ProtocolTest do
  use ExUnit.Case, async: true

  alias Accord.IR
  alias Accord.IR.{Branch, State, Track, Transition}

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

  defmodule BlockFormProtocol do
    use Accord.Protocol

    initial(:unlocked)

    track(:holder, :term, default: nil)
    track(:fence_token, :non_neg_integer, default: 0)

    state :unlocked do
      on {:acquire, _client_id :: term(), _token :: pos_integer()} do
        reply({:ok, pos_integer()})
        goto(:locked)

        guard(fn {:acquire, _client_id, token}, tracks ->
          token > tracks.fence_token
        end)

        update(fn {:acquire, client_id, token}, _reply, tracks ->
          %{tracks | holder: client_id, fence_token: token}
        end)
      end
    end

    state :locked do
      on {:release, _client_id :: term(), _token :: pos_integer()} do
        reply(:ok)
        goto(:unlocked)

        guard(fn {:release, client_id, token}, tracks ->
          client_id == tracks.holder and token == tracks.fence_token
        end)

        update(fn _msg, _reply, tracks -> %{tracks | holder: nil} end)
      end
    end

    state(:expired, terminal: true)

    anystate do
      on(:ping, reply: :pong)
    end
  end

  defmodule BranchingProtocol do
    use Accord.Protocol

    initial(:waiting)

    track(:balance, :non_neg_integer, default: 1000)

    state :waiting do
      on {:bet, _chips :: pos_integer()} do
        guard(fn {:bet, chips}, tracks -> chips <= tracks.balance end)
        branch({:ok, term()}, goto: :dealt)
        branch({:error, :insufficient_funds}, goto: :waiting)
      end
    end

    state(:dealt, terminal: true)
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

  describe "__ir__/0 — block form with tracks and guards" do
    test "tracks are populated" do
      ir = BlockFormProtocol.__ir__()
      assert length(ir.tracks) == 2

      holder = Enum.find(ir.tracks, &(&1.name == :holder))
      assert %Track{type: :term, default: nil} = holder

      fence = Enum.find(ir.tracks, &(&1.name == :fence_token))
      assert %Track{type: :non_neg_integer, default: 0} = fence
    end

    test "block form transition has guard" do
      ir = BlockFormProtocol.__ir__()
      [acquire] = ir.states[:unlocked].transitions

      assert acquire.guard != nil
      assert is_function(acquire.guard.fun, 2)
      assert acquire.guard.ast != nil
    end

    test "block form transition has update" do
      ir = BlockFormProtocol.__ir__()
      [acquire] = ir.states[:unlocked].transitions

      assert acquire.update != nil
      assert is_function(acquire.update.fun, 3)
    end

    test "block form transition has reply and goto" do
      ir = BlockFormProtocol.__ir__()
      [acquire] = ir.states[:unlocked].transitions

      assert [%Branch{reply_type: {:tagged, :ok, :pos_integer}, next_state: :locked}] =
               acquire.branches
    end

    test "guard function evaluates correctly" do
      ir = BlockFormProtocol.__ir__()
      [acquire] = ir.states[:unlocked].transitions

      tracks = %{fence_token: 5, holder: nil}
      assert acquire.guard.fun.({:acquire, :c1, 10}, tracks) == true
      assert acquire.guard.fun.({:acquire, :c1, 3}, tracks) == false
    end

    test "update function works correctly" do
      ir = BlockFormProtocol.__ir__()
      [acquire] = ir.states[:unlocked].transitions

      tracks = %{fence_token: 0, holder: nil}
      new_tracks = acquire.update.fun.({:acquire, :c1, 5}, {:ok, 5}, tracks)
      assert new_tracks.holder == :c1
      assert new_tracks.fence_token == 5
    end
  end

  describe "__ir__/0 — branching form" do
    test "branches are populated from branch macro" do
      ir = BranchingProtocol.__ir__()
      [bet] = ir.states[:waiting].transitions

      assert length(bet.branches) == 2

      [ok_branch, error_branch] = bet.branches
      assert ok_branch.reply_type == {:tagged, :ok, :term}
      assert ok_branch.next_state == :dealt
      assert error_branch.reply_type == {:tagged, :error, {:literal, :insufficient_funds}}
      assert error_branch.next_state == :waiting
    end

    test "branching transition has guard but no update" do
      ir = BranchingProtocol.__ir__()
      [bet] = ir.states[:waiting].transitions

      assert bet.guard != nil
      assert bet.update == nil
    end

    test "guard evaluates for branching" do
      ir = BranchingProtocol.__ir__()
      [bet] = ir.states[:waiting].transitions

      assert bet.guard.fun.({:bet, 500}, %{balance: 1000}) == true
      assert bet.guard.fun.({:bet, 1500}, %{balance: 1000}) == false
    end
  end

  describe "__compiled__/0 and Monitor module" do
    test "generates __compiled__/0" do
      compiled = SimpleProtocol.__compiled__()
      assert %Accord.Monitor.Compiled{} = compiled
      assert compiled.ir.name == SimpleProtocol
      assert is_map(compiled.transition_table.table)
      assert is_map(compiled.track_init)
    end

    test "generates nested Monitor module" do
      assert Code.ensure_loaded?(SimpleProtocol.Monitor)
      assert function_exported?(SimpleProtocol.Monitor, :start_link, 1)
      assert function_exported?(SimpleProtocol.Monitor, :child_spec, 1)
    end
  end

  describe "validation — compile-time errors" do
    test "undefined goto target raises CompileError" do
      assert_raise CompileError, ~r/undefined state reference/, fn ->
        defmodule BadGotoTarget do
          use Accord.Protocol

          initial(:ready)

          state :ready do
            on(:ping, reply: :pong, goto: :nonexistent)
          end
        end
      end
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
