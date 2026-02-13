defmodule Accord do
  @moduledoc """
  Runtime protocol contracts for Elixir with blame assignment.

  Accord monitors sit between client and server, validating messages
  against a protocol specification and assigning blame on violations.

  ## Usage

      # Define a protocol
      defmodule Counter.Protocol do
        use Accord.Protocol
        initial :ready
        state :ready do
          on {:increment, _n :: pos_integer()}, reply: {:ok, integer()}, goto: :ready
          on :stop, reply: :stopped, goto: :stopped
        end
        state :stopped, terminal: true
      end

      # Start a monitor
      {:ok, monitor} = Counter.Protocol.Monitor.start_link(upstream: server_pid)

      # Send messages through the monitor
      Accord.call(monitor, {:increment, 5})
  """

  @doc """
  Sends a synchronous call through a monitor.
  """
  @spec call(pid() | atom(), term(), timeout()) :: term()
  defdelegate call(monitor, message, timeout \\ 5_000), to: Accord.Monitor

  @doc """
  Sends an asynchronous cast through a monitor.
  """
  @spec cast(pid() | atom(), term()) :: :ok
  defdelegate cast(monitor, message), to: Accord.Monitor
end
