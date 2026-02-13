defmodule Accord.Property.CounterStatemTest do
  @moduledoc """
  PropCheck.StateM test for the Counter protocol.

  Exercises basic protocol monitoring: valid messages, wrong-state
  messages, bad-type messages, anystate, cast, terminal state, and
  server fault injection.
  """
  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM.ModelDSL

  @moduletag :property

  alias Accord.Monitor
  alias Accord.Test.Counter
  alias Accord.Test.FaultyServer

  # -- Model State --

  defstruct [
    :monitor,
    :faulty_server,
    protocol_state: :ready,
    counter_value: 0,
    terminal: false,
    pending_fault: nil
  ]

  # -- PropCheck Callbacks --

  def initial_state, do: %__MODULE__{}

  def command_gen(%__MODULE__{terminal: true}) do
    # After terminal state, only send messages that should fail.
    frequency([
      {3, {:send_after_terminal, [gen_valid_message()]}},
      {1, {:send_ping_after_terminal, []}}
    ])
  end

  def command_gen(%__MODULE__{pending_fault: fault}) when fault != nil do
    # A fault is pending — send a valid message to trigger it.
    frequency([
      {5, {:send_increment, [gen_pos_integer()]}},
      {3, {:send_get, []}}
    ])
  end

  def command_gen(%__MODULE__{}) do
    frequency([
      # Valid commands
      {5, {:send_increment, [gen_pos_integer()]}},
      {3, {:send_decrement, [gen_pos_integer()]}},
      {3, {:send_get, []}},
      {2, {:send_reset, []}},
      # Anystate
      {3, {:send_ping, []}},
      {1, {:send_heartbeat, []}},
      # Invalid: bad argument type
      {2, {:send_bad_type_increment, [gen_bad_pos_integer()]}},
      # Invalid: unknown message
      {1, {:send_unknown, []}},
      # Fault injection
      {1, {:inject_wrong_reply, []}},
      # Terminal
      {1, {:send_stop, []}}
    ])
  end

  # -- Generators --

  defp gen_pos_integer, do: integer(1, 100)
  defp gen_bad_pos_integer, do: oneof([integer(-100, 0), binary(), boolean()])

  defp gen_valid_message do
    oneof([
      {:increment, gen_pos_integer()},
      {:decrement, gen_pos_integer()},
      :get,
      :reset,
      :ping
    ])
  end

  # -- Commands --

  defcommand :send_increment do
    def impl(amount) do
      monitor = Process.get(:test_monitor)
      Monitor.call(monitor, {:increment, amount})
    end

    def post(%__MODULE__{pending_fault: :wrong_reply_type}, [_amount], result) do
      match?({:accord_violation, %{blame: :server, kind: :invalid_reply}}, result)
    end

    def post(%__MODULE__{counter_value: val}, [amount], result) do
      result == {:ok, val + amount}
    end

    def next(state, [amount], _result) do
      case state.pending_fault do
        :wrong_reply_type ->
          # Fault consumed, server state unchanged (faulty server forwarded).
          %{state | pending_fault: nil}

        nil ->
          %{state | counter_value: state.counter_value + amount}
      end
    end
  end

  defcommand :send_decrement do
    def impl(amount) do
      monitor = Process.get(:test_monitor)
      Monitor.call(monitor, {:decrement, amount})
    end

    def post(%__MODULE__{counter_value: val}, [amount], result) do
      result == {:ok, val - amount}
    end

    def next(state, [amount], _result) do
      %{state | counter_value: state.counter_value - amount}
    end
  end

  defcommand :send_get do
    def impl do
      monitor = Process.get(:test_monitor)
      Monitor.call(monitor, :get)
    end

    def post(%__MODULE__{pending_fault: :wrong_reply_type}, [], result) do
      match?({:accord_violation, %{blame: :server, kind: :invalid_reply}}, result)
    end

    def post(%__MODULE__{counter_value: val}, [], result) do
      result == {:value, val}
    end

    def next(state, [], _result) do
      case state.pending_fault do
        :wrong_reply_type -> %{state | pending_fault: nil}
        nil -> state
      end
    end
  end

  defcommand :send_reset do
    def impl do
      monitor = Process.get(:test_monitor)
      Monitor.call(monitor, :reset)
    end

    def post(_state, [], result), do: result == {:ok, 0}

    def next(state, [], _result) do
      %{state | counter_value: 0}
    end
  end

  defcommand :send_stop do
    def impl do
      monitor = Process.get(:test_monitor)
      Monitor.call(monitor, :stop)
    end

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

    def post(_state, [], result), do: result == :pong
  end

  defcommand :send_heartbeat do
    def impl do
      monitor = Process.get(:test_monitor)
      Monitor.cast(monitor, :heartbeat)
    end

    def post(_state, [], result), do: result == :ok
  end

  defcommand :send_bad_type_increment do
    def impl(bad_arg) do
      monitor = Process.get(:test_monitor)
      Monitor.call(monitor, {:increment, bad_arg})
    end

    def post(_state, [_bad_arg], result) do
      match?({:accord_violation, %{blame: :client, kind: :argument_type}}, result)
    end
  end

  defcommand :send_unknown do
    def impl do
      monitor = Process.get(:test_monitor)
      Monitor.call(monitor, :totally_unknown_message)
    end

    def post(_state, [], result) do
      match?({:accord_violation, %{blame: :client, kind: :invalid_message}}, result)
    end
  end

  defcommand :send_after_terminal do
    def impl(message) do
      monitor = Process.get(:test_monitor)
      Monitor.call(monitor, message)
    end

    def post(_state, [_msg], result) do
      match?({:accord_violation, %{blame: :client, kind: :session_ended}}, result)
    end
  end

  defcommand :send_ping_after_terminal do
    def impl do
      monitor = Process.get(:test_monitor)
      Monitor.call(monitor, :ping)
    end

    def post(_state, [], result) do
      match?({:accord_violation, %{blame: :client, kind: :session_ended}}, result)
    end
  end

  defcommand :inject_wrong_reply do
    def impl do
      faulty = Process.get(:test_faulty_server)
      FaultyServer.inject_fault(faulty, :wrong_reply_type)
    end

    def post(_state, [], result), do: result == :ok

    def next(state, [], _result) do
      %{state | pending_fault: :wrong_reply_type}
    end
  end

  # -- Property --

  property "counter protocol monitor handles all message classes correctly",
           [:verbose, numtests: 100, max_size: 30] do
    forall cmds <- commands(__MODULE__) do
      # Start fresh server + monitor for each test run.
      {:ok, faulty} = FaultyServer.start_link(Counter.Server)
      compiled = Counter.Protocol.__compiled__()
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
