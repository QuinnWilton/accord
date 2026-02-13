defmodule Accord.Property.LockStatemTest do
  @moduledoc """
  PropCheck.StateM test for the Lock protocol.

  Exercises tracks, guards, and guard failure blame. The lock protocol
  enforces monotonic fence tokens, so stale-token acquires fail the guard
  (client blame) while valid acquires mutate tracked state.

  NOTE: PropCheck.StateM.ModelDSL's `defcommand` macro does not rename
  `def` clauses with `when` guards (it only pattern-matches on the
  non-guard form). All dispatching must use pattern matching or explicit
  cond/if inside a single clause, never `when` guards.
  """
  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM.ModelDSL

  @moduletag :property

  alias Accord.Monitor
  alias Accord.Test.FaultyServer
  alias Accord.Test.Lock

  # -- Model State --

  defstruct protocol_state: :unlocked,
            holder: nil,
            fence_token: 0,
            terminal: false,
            pending_fault: nil

  # -- PropCheck Callbacks --

  def initial_state, do: %__MODULE__{}

  def command_gen(%__MODULE__{terminal: true}) do
    frequency([
      {3, {:send_after_terminal, [gen_valid_message()]}},
      {1, {:send_ping_after_terminal, []}}
    ])
  end

  def command_gen(%__MODULE__{pending_fault: :wrong_reply_type}) do
    # A fault is pending — send a valid message to trigger it.
    {:send_acquire, [gen_client_id(), gen_token()]}
  end

  def command_gen(%__MODULE__{protocol_state: :unlocked}) do
    frequency([
      # Valid: acquire with fresh token.
      {5, {:send_acquire, [gen_client_id(), gen_token()]}},
      # Invalid: release while unlocked.
      {2, {:send_release, [gen_client_id(), gen_token()]}},
      # Guard fail: acquire with stale token (token 0 → arg type error).
      {2, {:send_acquire_stale, [gen_client_id()]}},
      # Anystate
      {2, {:send_ping, []}},
      {1, {:send_heartbeat, []}},
      # Fault injection
      {1, {:inject_wrong_reply, []}},
      # Terminal
      {1, {:send_stop, []}}
    ])
  end

  def command_gen(%__MODULE__{protocol_state: :locked, holder: holder, fence_token: ft}) do
    frequency([
      # Valid: release with correct holder and token.
      {4, {:send_release_valid, [exactly(holder), exactly(ft)]}},
      # Valid: acquire with fresh token (preempt).
      {3, {:send_acquire, [gen_client_id(), gen_token()]}},
      # Guard fail: release with wrong holder.
      {2, {:send_release_wrong_holder, [gen_client_id(), exactly(ft)]}},
      # Guard fail: release with wrong token.
      {2, {:send_release_wrong_token, [exactly(holder), gen_token()]}},
      # Guard fail: acquire with stale token.
      {2, {:send_acquire_stale, [gen_client_id()]}},
      # Anystate
      {2, {:send_ping, []}},
      {1, {:send_heartbeat, []}},
      # Fault injection
      {1, {:inject_wrong_reply, []}},
      # Terminal
      {1, {:send_stop, []}}
    ])
  end

  # -- Generators --

  defp gen_client_id, do: oneof([:c1, :c2, :c3])
  defp gen_token, do: integer(1, 50)

  defp gen_valid_message do
    oneof([
      {:acquire, gen_client_id(), gen_token()},
      {:release, gen_client_id(), gen_token()},
      :ping
    ])
  end

  # -- Commands --

  # No `when` guards in defcommand blocks — PropCheck's macro doesn't rename them.

  defcommand :send_acquire do
    def impl(client_id, token) do
      monitor = Process.get(:test_monitor)
      Monitor.call(monitor, {:acquire, client_id, token})
    end

    def pre(%__MODULE__{terminal: true}, [_cid, _token]), do: false
    def pre(_, _), do: true

    def post(%__MODULE__{fence_token: ft, pending_fault: fault}, [_cid, token], result) do
      cond do
        token <= ft ->
          # Guard fails before forwarding — fault not consumed.
          match?({:accord_violation, %{blame: :client, kind: :guard_failed}}, result)

        fault == :wrong_reply_type ->
          # Guard passes, message forwarded, fault triggers.
          match?({:accord_violation, %{blame: :server, kind: :invalid_reply}}, result)

        true ->
          result == {:ok, token}
      end
    end

    def next(%__MODULE__{fence_token: ft} = state, [cid, token], _result) do
      cond do
        token <= ft ->
          # Guard failed — state unchanged, fault not consumed.
          state

        state.pending_fault == :wrong_reply_type ->
          # Fault consumed, server state unchanged.
          %{state | pending_fault: nil}

        true ->
          %{state | holder: cid, fence_token: token, protocol_state: :locked}
      end
    end
  end

  defcommand :send_acquire_stale do
    def impl(client_id) do
      # Token 0 fails pos_integer type check (0 is not positive).
      monitor = Process.get(:test_monitor)
      Monitor.call(monitor, {:acquire, client_id, 0})
    end

    def pre(%__MODULE__{terminal: true}, _), do: false
    def pre(_, _), do: true

    def post(_state, [_cid], result) do
      match?({:accord_violation, %{blame: :client, kind: :argument_type}}, result)
    end
  end

  defcommand :send_release_valid do
    def impl(client_id, token) do
      monitor = Process.get(:test_monitor)
      Monitor.call(monitor, {:release, client_id, token})
    end

    def pre(%__MODULE__{protocol_state: :locked}, _), do: true
    def pre(_, _), do: false

    def post(_state, [_cid, _token], result) do
      result == :ok
    end

    def next(state, [_cid, _token], _result) do
      %{state | holder: nil, protocol_state: :unlocked}
    end
  end

  defcommand :send_release do
    def impl(client_id, token) do
      monitor = Process.get(:test_monitor)
      Monitor.call(monitor, {:release, client_id, token})
    end

    def pre(%__MODULE__{protocol_state: :unlocked, terminal: false}, _), do: true
    def pre(_, _), do: false

    def post(_state, [_cid, _token], result) do
      match?({:accord_violation, %{blame: :client, kind: :invalid_message}}, result)
    end
  end

  defcommand :send_release_wrong_holder do
    def impl(client_id, token) do
      monitor = Process.get(:test_monitor)
      Monitor.call(monitor, {:release, client_id, token})
    end

    def pre(%__MODULE__{protocol_state: :locked, holder: holder}, [cid, _token]) do
      cid != holder
    end

    def pre(_, _), do: false

    def post(_state, [_cid, _token], result) do
      match?({:accord_violation, %{blame: :client, kind: :guard_failed}}, result)
    end
  end

  defcommand :send_release_wrong_token do
    def impl(client_id, token) do
      monitor = Process.get(:test_monitor)
      Monitor.call(monitor, {:release, client_id, token})
    end

    def pre(%__MODULE__{protocol_state: :locked, fence_token: ft}, [_cid, token]) do
      token != ft
    end

    def pre(_, _), do: false

    def post(_state, [_cid, _token], result) do
      match?({:accord_violation, %{blame: :client, kind: :guard_failed}}, result)
    end
  end

  defcommand :send_stop do
    def impl do
      monitor = Process.get(:test_monitor)
      Monitor.call(monitor, :stop)
    end

    def pre(%__MODULE__{terminal: true}, _), do: false
    def pre(_, _), do: true

    def post(_state, [], result), do: result == :stopped

    def next(state, [], _result) do
      %{state | protocol_state: :stopped, terminal: true}
    end
  end

  defcommand :send_ping do
    def impl do
      monitor = Process.get(:test_monitor)
      Monitor.call(monitor, :ping)
    end

    def pre(%__MODULE__{terminal: true}, _), do: false
    def pre(_, _), do: true

    def post(_state, [], result), do: result == :pong
  end

  defcommand :send_heartbeat do
    def impl do
      monitor = Process.get(:test_monitor)
      Monitor.cast(monitor, :heartbeat)
    end

    def pre(%__MODULE__{terminal: true}, _), do: false
    def pre(_, _), do: true

    def post(_state, [], result), do: result == :ok
  end

  defcommand :send_after_terminal do
    def impl(message) do
      monitor = Process.get(:test_monitor)
      Monitor.call(monitor, message)
    end

    def pre(%__MODULE__{terminal: true}, _), do: true
    def pre(_, _), do: false

    def post(_state, [_msg], result) do
      match?({:accord_violation, %{blame: :client, kind: :session_ended}}, result)
    end
  end

  defcommand :send_ping_after_terminal do
    def impl do
      monitor = Process.get(:test_monitor)
      Monitor.call(monitor, :ping)
    end

    def pre(%__MODULE__{terminal: true}, _), do: true
    def pre(_, _), do: false

    def post(_state, [], result) do
      match?({:accord_violation, %{blame: :client, kind: :session_ended}}, result)
    end
  end

  defcommand :inject_wrong_reply do
    def impl do
      faulty = Process.get(:test_faulty_server)
      FaultyServer.inject_fault(faulty, :wrong_reply_type)
    end

    def pre(%__MODULE__{terminal: true}, _), do: false
    def pre(%__MODULE__{pending_fault: nil}, _), do: true
    def pre(_, _), do: false

    def post(_state, [], result), do: result == :ok

    def next(state, [], _result) do
      %{state | pending_fault: :wrong_reply_type}
    end
  end

  # -- Property --

  property "lock protocol monitor handles tracks, guards, and faults correctly",
           [:verbose, numtests: 200, max_size: 30] do
    forall cmds <- commands(__MODULE__) do
      {:ok, faulty} = FaultyServer.start_link(Lock.Server)
      compiled = Lock.Protocol.__compiled__()
      {:ok, monitor} = Monitor.start_link(compiled, upstream: faulty, violation_policy: :log)

      Process.put(:test_monitor, monitor)
      Process.put(:test_faulty_server, faulty)

      {history, _state, result} = run_commands(__MODULE__, cmds)

      # Cleanup.
      if Process.alive?(monitor), do: GenServer.stop(monitor, :normal, 100)
      if Process.alive?(faulty), do: GenServer.stop(faulty, :normal, 100)

      (result == :ok)
      |> when_fail(
        IO.puts("""
        History: #{inspect(history, pretty: true)}
        Result: #{inspect(result)}
        """)
      )
    end
  end
end
