defmodule Accord.MonitorTest do
  use ExUnit.Case

  alias Accord.IR
  alias Accord.IR.{Branch, State, Transition}
  alias Accord.Monitor
  alias Accord.Monitor.Compiled
  alias Accord.Pass.{BuildTransitionTable, BuildTrackInit}

  # -- Simple test server --

  defmodule EchoServer do
    use GenServer

    def start_link(replies \\ %{}) do
      GenServer.start_link(__MODULE__, replies)
    end

    @impl true
    def init(replies), do: {:ok, replies}

    @impl true
    def handle_call(message, _from, replies) do
      tag = if is_atom(message), do: message, else: elem(message, 0)

      case Map.get(replies, tag) do
        nil -> {:reply, :default_reply, replies}
        fun when is_function(fun, 1) -> {:reply, fun.(message), replies}
        value -> {:reply, value, replies}
      end
    end

    @impl true
    def handle_cast(_message, state), do: {:noreply, state}
  end

  defp sample_ir do
    %IR{
      name: Test.Protocol,
      initial: :ready,
      states: %{
        ready: %State{
          name: :ready,
          transitions: [
            %Transition{
              message_pattern: {:increment, :_},
              message_types: [:pos_integer],
              kind: :call,
              branches: [%Branch{reply_type: {:tagged, :ok, :integer}, next_state: :ready}]
            },
            %Transition{
              message_pattern: :stop,
              message_types: [],
              kind: :call,
              branches: [%Branch{reply_type: {:literal, :stopped}, next_state: :stopped}]
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
          branches: [%Branch{reply_type: {:literal, :pong}, next_state: :__same__}]
        },
        %Transition{
          message_pattern: :heartbeat,
          message_types: [],
          kind: :cast,
          branches: []
        }
      ]
    }
  end

  defp compile_ir(ir) do
    {:ok, table} = BuildTransitionTable.run(ir)
    {:ok, track_init} = BuildTrackInit.run(ir)
    %Compiled{ir: ir, transition_table: table, track_init: track_init}
  end

  defp start_monitor(compiled, server, opts \\ []) do
    policy = Keyword.get(opts, :violation_policy, :log)
    Monitor.start_link(compiled, upstream: server, violation_policy: policy)
  end

  describe "basic message pipeline" do
    setup do
      compiled = compile_ir(sample_ir())

      {:ok, server} =
        EchoServer.start_link(%{
          increment: fn {:increment, n} -> {:ok, n} end,
          stop: :stopped,
          ping: :pong
        })

      {:ok, monitor} = start_monitor(compiled, server)
      %{monitor: monitor, compiled: compiled, server: server}
    end

    test "forwards valid call and returns reply", %{monitor: monitor} do
      assert {:ok, 5} = Monitor.call(monitor, {:increment, 5})
    end

    test "handles anystate transition", %{monitor: monitor} do
      assert :pong = Monitor.call(monitor, :ping)
    end

    test "transitions to next state", %{monitor: monitor} do
      assert {:ok, 1} = Monitor.call(monitor, {:increment, 1})
      assert :stopped = Monitor.call(monitor, :stop)
    end

    test "anystate stays in current state", %{monitor: monitor} do
      assert :pong = Monitor.call(monitor, :ping)
      assert {:ok, 5} = Monitor.call(monitor, {:increment, 5})
    end
  end

  describe "cast pipeline" do
    setup do
      compiled = compile_ir(sample_ir())
      {:ok, server} = EchoServer.start_link()
      {:ok, monitor} = start_monitor(compiled, server)
      %{monitor: monitor}
    end

    test "valid cast succeeds", %{monitor: monitor} do
      assert :ok = Monitor.cast(monitor, :heartbeat)
      # Give it a moment to process.
      :timer.sleep(10)
      assert Process.alive?(monitor)
    end
  end

  describe "client blame — :invalid_message" do
    setup do
      compiled = compile_ir(sample_ir())
      {:ok, server} = EchoServer.start_link()
      {:ok, monitor} = start_monitor(compiled, server)
      %{monitor: monitor}
    end

    test "rejects message not valid in state", %{monitor: monitor} do
      assert {:accord_violation, violation} = Monitor.call(monitor, :unknown_msg)
      assert violation.blame == :client
      assert violation.kind == :invalid_message
    end
  end

  describe "client blame — :argument_type" do
    setup do
      compiled = compile_ir(sample_ir())
      {:ok, server} = EchoServer.start_link()
      {:ok, monitor} = start_monitor(compiled, server)
      %{monitor: monitor}
    end

    test "rejects bad argument type", %{monitor: monitor} do
      assert {:accord_violation, violation} = Monitor.call(monitor, {:increment, -1})
      assert violation.blame == :client
      assert violation.kind == :argument_type
    end

    test "rejects non-integer argument", %{monitor: monitor} do
      assert {:accord_violation, violation} = Monitor.call(monitor, {:increment, "five"})
      assert violation.blame == :client
      assert violation.kind == :argument_type
    end
  end

  describe "client blame — :session_ended" do
    setup do
      compiled = compile_ir(sample_ir())

      {:ok, server} =
        EchoServer.start_link(%{
          stop: :stopped,
          ping: :pong
        })

      {:ok, monitor} = start_monitor(compiled, server)
      :stopped = Monitor.call(monitor, :stop)
      %{monitor: monitor}
    end

    test "rejects call after terminal state", %{monitor: monitor} do
      assert {:accord_violation, violation} = Monitor.call(monitor, :ping)
      assert violation.blame == :client
      assert violation.kind == :session_ended
    end
  end

  describe "server blame — :invalid_reply" do
    setup do
      compiled = compile_ir(sample_ir())

      {:ok, server} =
        EchoServer.start_link(%{
          increment: :wrong_reply_shape
        })

      {:ok, monitor} = start_monitor(compiled, server)
      %{monitor: monitor}
    end

    test "detects server returning wrong reply type", %{monitor: monitor} do
      assert {:accord_violation, violation} = Monitor.call(monitor, {:increment, 1})
      assert violation.blame == :server
      assert violation.kind == :invalid_reply
    end
  end

  describe "violation policies" do
    test ":crash stops the monitor" do
      compiled = compile_ir(sample_ir())
      {:ok, server} = EchoServer.start_link()
      {:ok, monitor} = start_monitor(compiled, server, violation_policy: :crash)

      # Trap exits so the test process isn't killed.
      Process.flag(:trap_exit, true)

      # Send invalid message — monitor replies then stops.
      assert {:accord_violation, _} = Monitor.call(monitor, :unknown_msg)

      assert_receive {:EXIT, ^monitor, {:protocol_violation, _}}
      refute Process.alive?(monitor)
    end

    test ":log keeps monitor alive" do
      compiled = compile_ir(sample_ir())
      {:ok, server} = EchoServer.start_link()
      {:ok, monitor} = start_monitor(compiled, server, violation_policy: :log)

      assert {:accord_violation, _} = Monitor.call(monitor, :unknown_msg)
      assert Process.alive?(monitor)
    end
  end
end
