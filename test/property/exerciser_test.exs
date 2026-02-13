defmodule Accord.Property.ExerciserTest do
  @moduledoc """
  Protocol exerciser tests for counter, lock, and blackjack servers.

  These tests verify that each server correctly conforms to its protocol
  specification by generating a mix of valid and invalid messages and
  checking that outcomes match expectations.
  """
  use ExUnit.Case, async: false
  use PropCheck

  @moduletag :property
  @moduletag :capture_log

  alias Accord.Test.ProtocolExerciser
  alias Accord.Test.ExerciserFailure

  # -- Non-conforming servers for negative testing --

  defmodule WrongReplyCounter do
    @moduledoc false
    use GenServer

    def start_link(opts \\ []) do
      initial = Keyword.get(opts, :initial, 0)
      GenServer.start_link(__MODULE__, initial, opts)
    end

    @impl true
    def init(initial), do: {:ok, initial}

    @impl true
    def handle_call({:increment, amount}, _from, count) do
      new = count + amount
      {:reply, {:ok, new}, new}
    end

    def handle_call({:decrement, amount}, _from, count) do
      new = count - amount
      {:reply, {:ok, new}, new}
    end

    # Bug: returns bare integer instead of {:value, integer()}.
    def handle_call(:get, _from, count) do
      {:reply, count, count}
    end

    def handle_call(:reset, _from, _count) do
      {:reply, {:ok, 0}, 0}
    end

    def handle_call(:stop, _from, count) do
      {:reply, :stopped, count}
    end

    def handle_call(:ping, _from, count) do
      {:reply, :pong, count}
    end

    @impl true
    def handle_cast(:heartbeat, count), do: {:noreply, count}
  end

  defmodule DecreasingTokenLock do
    @moduledoc false
    use GenServer

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def init(_opts) do
      {:ok, %{holder: nil, counter: 100}}
    end

    @impl true
    def handle_call({:acquire, client_id}, _from, state) do
      if state.holder == nil do
        # Bug: counter decrements, producing monotonically decreasing tokens.
        token = state.counter
        {:reply, {:ok, token}, %{state | holder: client_id, counter: state.counter - 1}}
      else
        {:reply, {:error, :already_held}, state}
      end
    end

    # Accepts any token so the exerciser can complete acquire-release cycles
    # regardless of what :proper_gen.pick produces for pos_integer().
    def handle_call({:release, _token}, _from, state) do
      {:reply, :ok, %{state | holder: nil}}
    end

    def handle_call(:stop, _from, state), do: {:reply, :stopped, state}
    def handle_call(:ping, _from, state), do: {:reply, :pong, state}

    @impl true
    def handle_cast(:heartbeat, state), do: {:noreply, state}
  end

  defmodule StaleHolderLock do
    @moduledoc false
    use GenServer

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def init(_opts) do
      {:ok, %{holder: nil, fence_token: 0, previous_holder: nil}}
    end

    @impl true
    def handle_call({:acquire, client_id}, _from, state) do
      if state.holder == nil do
        new_token = state.fence_token + 1

        # Bug: sets holder to previous holder instead of current client.
        new_state = %{
          state
          | holder: state.previous_holder,
            fence_token: new_token,
            previous_holder: client_id
        }

        {:reply, {:ok, new_token}, new_state}
      else
        {:reply, {:error, :already_held}, state}
      end
    end

    def handle_call({:release, token}, _from, state) do
      if token == state.fence_token do
        {:reply, :ok, %{state | holder: nil}}
      else
        {:reply, {:error, :invalid_token}, state}
      end
    end

    def handle_call(:stop, _from, state), do: {:reply, :stopped, state}
    def handle_call(:ping, _from, state), do: {:reply, :pong, state}

    @impl true
    def handle_cast(:heartbeat, state), do: {:noreply, state}
  end

  defmodule WrappingTokenLock do
    @moduledoc false
    use GenServer

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def init(_opts) do
      # Counter starts at 4 so first token is rem(4, 5) + 1 = 5.
      {:ok, %{holder: nil, counter: 4}}
    end

    @impl true
    def handle_call({:acquire, client_id}, _from, state) do
      if state.holder == nil do
        # Bug: token wraps around at 5 (sequence: 5, 1, 2, 3, 4, 5, 1, ...).
        token = rem(state.counter, 5) + 1
        {:reply, {:ok, token}, %{state | holder: client_id, counter: state.counter + 1}}
      else
        {:reply, {:error, :already_held}, state}
      end
    end

    # Accepts any token so the exerciser can complete acquire-release cycles
    # regardless of what :proper_gen.pick produces for pos_integer().
    def handle_call({:release, _token}, _from, state) do
      {:reply, :ok, %{state | holder: nil}}
    end

    def handle_call(:stop, _from, state), do: {:reply, :stopped, state}
    def handle_call(:ping, _from, state), do: {:reply, :pong, state}

    @impl true
    def handle_cast(:heartbeat, state), do: {:noreply, state}
  end

  # -- Conforming implementation tests --

  describe "counter" do
    @tag :property
    test "server conforms to counter protocol" do
      ProtocolExerciser.run(
        protocol: Accord.Test.Counter.Protocol,
        server: Accord.Test.Counter.Server,
        numtests: 200,
        max_commands: 30
      )
    end
  end

  describe "lock" do
    @tag :property
    test "server conforms to lock protocol" do
      ProtocolExerciser.run(
        protocol: Accord.Test.Lock.Protocol,
        server: Accord.Test.Lock.Server,
        numtests: 200,
        max_commands: 30
      )
    end
  end

  describe "blackjack" do
    @tag :property
    test "server conforms to blackjack protocol" do
      ProtocolExerciser.run(
        protocol: Accord.Test.Blackjack.Protocol,
        server: Accord.Test.Blackjack.Server,
        numtests: 200,
        max_commands: 30
      )
    end
  end

  # -- Non-conforming implementation tests --

  describe "non-conforming implementations" do
    @tag :property
    test "detects invalid reply from counter with wrong reply type" do
      error =
        assert_raise ExerciserFailure, fn ->
          ProtocolExerciser.run(
            protocol: Accord.Test.Counter.Protocol,
            server: WrongReplyCounter,
            numtests: 200,
            max_commands: 30
          )
        end

      failing = Enum.find(error.steps, &(not &1.passed))
      assert failing != nil
      assert {:accord_violation, %{blame: :server, kind: :invalid_reply}} = failing.actual
    end

    @tag :property
    test "detects action property violation from lock with decreasing tokens" do
      error =
        assert_raise ExerciserFailure, fn ->
          ProtocolExerciser.run(
            protocol: Accord.Test.Lock.Protocol,
            server: DecreasingTokenLock,
            numtests: 200,
            max_commands: 30
          )
        end

      assert Enum.any?(error.property_violations, fn v ->
               v.kind == :action_violated and v.context.property == :monotonic_tokens
             end)
    end

    @tag :property
    test "detects invalid reply from lock with stale holder bug" do
      error =
        assert_raise ExerciserFailure, fn ->
          ProtocolExerciser.run(
            protocol: Accord.Test.Lock.Protocol,
            server: StaleHolderLock,
            numtests: 200,
            max_commands: 30
          )
        end

      failing = Enum.find(error.steps, &(not &1.passed))
      assert failing != nil
      assert {:accord_violation, %{blame: :server, kind: :invalid_reply}} = failing.actual
    end

    @tag :property
    test "detects action property violation from lock with wrapping fence token" do
      error =
        assert_raise ExerciserFailure, fn ->
          ProtocolExerciser.run(
            protocol: Accord.Test.Lock.Protocol,
            server: WrappingTokenLock,
            numtests: 500,
            max_commands: 50
          )
        end

      assert Enum.any?(error.property_violations, fn v ->
               v.kind == :action_violated and v.context.property == :monotonic_tokens
             end)
    end
  end
end
