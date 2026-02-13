defmodule Accord.Test.Counter.Protocol do
  @moduledoc """
  Simple counter protocol for testing.

  Supports increment, decrement, get, reset, and stop operations.
  Anystate ping and cast heartbeat.
  """
  use Accord.Protocol

  initial(:ready)

  state :ready do
    on({:increment, _amount :: pos_integer()}, reply: {:ok, integer()}, goto: :ready)
    on({:decrement, _amount :: pos_integer()}, reply: {:ok, integer()}, goto: :ready)
    on(:get, reply: {:value, integer()}, goto: :ready)
    on(:reset, reply: {:ok, integer()}, goto: :ready)
    on(:stop, reply: :stopped, goto: :stopped)
  end

  state(:stopped, terminal: true)

  anystate do
    on(:ping, reply: :pong)
    cast(:heartbeat)
  end
end

defmodule Accord.Test.Counter.Server do
  @moduledoc """
  A correct counter server that faithfully implements Counter.Protocol.
  """
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

  def handle_call(:get, _from, count) do
    {:reply, {:value, count}, count}
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
