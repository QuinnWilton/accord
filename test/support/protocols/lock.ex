defmodule Accord.Test.Lock.Protocol do
  @moduledoc """
  Distributed lock protocol for testing tracks and guards.

  The lock protocol enforces monotonic fence tokens — each acquire must
  use a strictly greater token than the previous one. This exercises
  guard evaluation, track mutation, and guard failure blame.
  """
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

    on(:stop, reply: :stopped, goto: :stopped)
  end

  state :locked do
    on {:release, _client_id :: term(), _token :: pos_integer()} do
      reply(:ok)
      goto(:unlocked)

      guard(fn {:release, client_id, token}, tracks ->
        client_id == tracks.holder and token == tracks.fence_token
      end)

      update(fn _msg, _reply, tracks ->
        %{tracks | holder: nil}
      end)
    end

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

    on(:stop, reply: :stopped, goto: :stopped)
  end

  state(:stopped, terminal: true)

  anystate do
    on(:ping, reply: :pong)
    cast(:heartbeat)
  end
end

defmodule Accord.Test.Lock.Server do
  @moduledoc """
  A correct lock server that faithfully implements Lock.Protocol.
  """
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(_opts) do
    {:ok, %{holder: nil, fence_token: 0}}
  end

  @impl true
  def handle_call({:acquire, client_id, token}, _from, state) do
    new_state = %{state | holder: client_id, fence_token: token}
    {:reply, {:ok, token}, new_state}
  end

  def handle_call({:release, _client_id, _token}, _from, state) do
    new_state = %{state | holder: nil}
    {:reply, :ok, new_state}
  end

  def handle_call(:stop, _from, state) do
    {:reply, :stopped, state}
  end

  def handle_call(:ping, _from, state) do
    {:reply, :pong, state}
  end

  @impl true
  def handle_cast(:heartbeat, state), do: {:noreply, state}
end
