defmodule Accord.Test.FaultyServer do
  @moduledoc """
  Wraps a correct server and injects faults on demand.

  ## Fault kinds

  - `:wrong_reply_type` — returns a value that doesn't match any branch type.
  - `:timeout` — doesn't reply within the timeout.
  - `{:corrupt_field, index, value}` — returns correct shape but wrong
    type at a position.
  """
  use GenServer

  def start_link(server_mod, server_args \\ [], opts \\ []) do
    GenServer.start_link(__MODULE__, {server_mod, server_args}, opts)
  end

  @doc """
  Injects a fault for the next `count` replies.
  """
  def inject_fault(pid, fault, count \\ 1) do
    GenServer.call(pid, {:inject_fault, fault, count})
  end

  @doc """
  Clears all pending faults.
  """
  def clear_faults(pid) do
    GenServer.call(pid, :clear_faults)
  end

  # -- Callbacks --

  @impl true
  def init({server_mod, server_args}) do
    {:ok, server} = apply(server_mod, :start_link, [server_args])
    {:ok, %{server: server, faults: :queue.new()}}
  end

  @impl true
  def handle_call({:inject_fault, fault, count}, _from, state) do
    faults =
      Enum.reduce(1..count, state.faults, fn _, q ->
        :queue.in(fault, q)
      end)

    {:reply, :ok, %{state | faults: faults}}
  end

  def handle_call(:clear_faults, _from, state) do
    {:reply, :ok, %{state | faults: :queue.new()}}
  end

  def handle_call(message, from, state) do
    case :queue.out(state.faults) do
      {{:value, fault}, rest} ->
        apply_fault(fault, message, from, %{state | faults: rest})

      {:empty, _} ->
        # No fault — forward to real server.
        reply = GenServer.call(state.server, message)
        {:reply, reply, state}
    end
  end

  @impl true
  def handle_cast(message, state) do
    GenServer.cast(state.server, message)
    {:noreply, state}
  end

  defp apply_fault(:wrong_reply_type, _message, _from, state) do
    {:reply, :__faulty_wrong_type__, state}
  end

  defp apply_fault(:timeout, _message, _from, state) do
    # Don't reply — the caller will time out.
    # We still need to return from handle_call, so noreply.
    {:noreply, state}
  end

  defp apply_fault({:corrupt_field, index, value}, message, _from, state) do
    # Get correct reply, then corrupt one field.
    reply = GenServer.call(state.server, message)

    corrupted =
      if is_tuple(reply) and tuple_size(reply) > index do
        put_elem(reply, index, value)
      else
        reply
      end

    {:reply, corrupted, state}
  end
end
