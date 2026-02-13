defmodule Accord.Test.Lock.Protocol do
  @moduledoc """
  Distributed fencing token lock protocol.

  Models a standard distributed lock with mutual exclusion and
  monotonically increasing fence tokens. The server generates a new
  token on each successful acquire. The client presents the token on
  release to prove ownership. Acquiring while locked is rejected.
  """
  use Accord.Protocol

  initial :unlocked

  track :holder, :term, default: nil
  track :fence_token, :non_neg_integer, default: 0

  state :unlocked do
    on {:acquire, _client_id :: term()} do
      reply {:ok, pos_integer()}
      goto :locked

      update fn {:acquire, cid}, {:ok, token}, tracks ->
        %{tracks | holder: cid, fence_token: token}
      end
    end

    on :stop, reply: :stopped, goto: :stopped
  end

  state :locked do
    on {:release, _token :: pos_integer()} do
      branch :ok, goto: :unlocked
      branch {:error, :invalid_token}, goto: :locked

      update fn _msg, reply, tracks ->
        case reply do
          :ok -> %{tracks | holder: nil}
          _ -> tracks
        end
      end
    end

    on {:acquire, _client_id :: term()} do
      reply {:error, :already_held}
      goto :locked
    end

    on :stop, reply: :stopped, goto: :stopped
  end

  state :stopped, terminal: true

  anystate do
    on :ping, reply: :pong
    cast :heartbeat
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
  def handle_call({:acquire, client_id}, _from, state) do
    if state.holder == nil do
      new_token = state.fence_token + 1
      new_state = %{state | holder: client_id, fence_token: new_token}
      {:reply, {:ok, new_token}, new_state}
    else
      {:reply, {:error, :already_held}, state}
    end
  end

  def handle_call({:release, token}, _from, state) do
    if token == state.fence_token do
      new_state = %{state | holder: nil}
      {:reply, :ok, new_state}
    else
      {:reply, {:error, :invalid_token}, state}
    end
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
