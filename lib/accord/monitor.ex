defmodule Accord.Monitor do
  @moduledoc """
  Runtime protocol monitor as an explicit gen_statem proxy.

  Sits between client and server, validating messages against the
  protocol specification and assigning blame on violations.

      Client ──msg──▶ [Monitor] ──msg──▶ Server
                          │
                     on violation:
                     log / reject / crash
  """

  @behaviour :gen_statem

  alias Accord.IR.Branch
  alias Accord.Monitor.{Compiled, TransitionTable}
  alias Accord.Type.Check
  alias Accord.Violation

  @type violation_policy :: :log | :reject | :crash | {module(), atom()}

  defstruct [
    :compiled,
    :upstream,
    :tracks,
    :violation_policy,
    call_timeout: 5_000
  ]

  # -- Public API --

  @doc """
  Starts a monitor process.

  ## Options

  - `:upstream` (required) — PID of the server to forward messages to.
  - `:violation_policy` — `:log` | `:reject` | `:crash` | `{mod, fun}`. Default `:crash`.
  - `:call_timeout` — timeout for upstream calls in ms. Default 5000.
  """
  @spec start_link(Compiled.t(), keyword()) :: :gen_statem.start_ret()
  def start_link(%Compiled{} = compiled, opts) do
    upstream = Keyword.fetch!(opts, :upstream)
    policy = Keyword.get(opts, :violation_policy, :crash)
    timeout = Keyword.get(opts, :call_timeout, 5_000)
    name = Keyword.get(opts, :name)

    init_arg = {compiled, upstream, policy, timeout}

    if name do
      :gen_statem.start_link({:local, name}, __MODULE__, init_arg, [])
    else
      :gen_statem.start_link(__MODULE__, init_arg, [])
    end
  end

  @doc """
  Sends a synchronous call through the monitor.
  """
  @spec call(pid() | atom(), term(), timeout()) :: term()
  def call(monitor, message, timeout \\ 5_000) do
    :gen_statem.call(monitor, {:accord_call, message}, timeout)
  end

  @doc """
  Sends an asynchronous cast through the monitor.
  """
  @spec cast(pid() | atom(), term()) :: :ok
  def cast(monitor, message) do
    :gen_statem.cast(monitor, {:accord_cast, message})
  end

  # -- gen_statem callbacks --

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init({compiled, upstream, policy, timeout}) do
    data = %__MODULE__{
      compiled: compiled,
      upstream: upstream,
      tracks: compiled.track_init,
      violation_policy: policy,
      call_timeout: timeout
    }

    {:ok, compiled.ir.initial, data}
  end

  @impl true
  # Synchronous call
  def handle_event({:call, from}, {:accord_call, message}, state, data) do
    handle_call(message, from, state, data)
  end

  # Asynchronous cast
  def handle_event(:cast, {:accord_cast, message}, state, data) do
    handle_cast(message, state, data)
  end

  # -- Call Pipeline --

  defp handle_call(message, from, state, data) do
    table = data.compiled.transition_table

    cond do
      TransitionTable.terminal?(table, state) ->
        violation = Violation.session_ended(state, message)
        handle_violation(violation, from, state, data)

      true ->
        case TransitionTable.lookup(table, state, message) do
          {:ok, transition} ->
            process_call_transition(transition, message, from, state, data)

          :error ->
            violation = Violation.invalid_message(state, message, valid_tags(table, state))
            handle_violation(violation, from, state, data)
        end
    end
  end

  defp process_call_transition(transition, message, from, state, data) do
    # Step 1: Type-check message arguments.
    case check_message_types(message, transition, state) do
      :ok ->
        # Step 2: Evaluate guard (if present).
        case evaluate_guard(transition.guard, message, data.tracks) do
          :ok ->
            # Step 3: Forward to upstream, get reply.
            forward_call(transition, message, from, state, data)

          {:error, :guard_failed} ->
            violation = Violation.guard_failed(state, message)
            handle_violation(violation, from, state, data)
        end

      {:error, violation} ->
        handle_violation(violation, from, state, data)
    end
  end

  defp forward_call(transition, message, from, state, data) do
    try do
      reply = GenServer.call(data.upstream, message, data.call_timeout)
      handle_reply(transition, message, reply, from, state, data)
    catch
      :exit, {:timeout, _} ->
        violation = Violation.timeout(state, message, data.call_timeout)
        handle_violation(violation, from, state, data)
    end
  end

  defp handle_reply(transition, message, reply, from, state, data) do
    reply_pairs =
      Enum.map(transition.branches, fn %Branch{reply_type: type, next_state: ns} ->
        {type, ns}
      end)

    case Check.check_reply(reply, reply_pairs) do
      {:ok, next_state} ->
        actual_next = if next_state == :__same__, do: state, else: next_state

        # Apply update if present.
        new_tracks = apply_update(transition.update, message, reply, data.tracks)
        new_data = %{data | tracks: new_tracks}

        {:next_state, actual_next, new_data, [{:reply, from, reply}]}

      {:error, _reason} ->
        valid = Enum.map(transition.branches, & &1.reply_type)
        violation = Violation.invalid_reply(state, message, reply, valid)
        handle_violation(violation, from, state, data)
    end
  end

  # -- Cast Pipeline --

  defp handle_cast(message, state, data) do
    table = data.compiled.transition_table

    cond do
      TransitionTable.terminal?(table, state) ->
        violation = Violation.session_ended(state, message)
        handle_cast_violation(violation, state, data)

      true ->
        case TransitionTable.lookup(table, state, message) do
          {:ok, transition} when transition.kind == :cast ->
            # Type-check message arguments.
            case check_message_types(message, transition, state) do
              :ok ->
                # Forward to upstream.
                GenServer.cast(data.upstream, message)
                {:keep_state, data}

              {:error, violation} ->
                handle_cast_violation(violation, state, data)
            end

          {:ok, _transition} ->
            # Found a :call transition, not valid for cast.
            violation = Violation.invalid_message(state, message, [])
            handle_cast_violation(violation, state, data)

          :error ->
            violation = Violation.invalid_message(state, message, valid_tags(table, state))
            handle_cast_violation(violation, state, data)
        end
    end
  end

  # -- Message Type Checking --

  defp check_message_types(_message, %{message_types: []}, _state), do: :ok

  defp check_message_types(message, transition, state) when is_tuple(message) do
    args = message |> Tuple.to_list() |> tl()
    types = transition.message_types

    if length(args) != length(types) do
      :ok
    else
      args
      |> Enum.zip(types)
      |> Enum.with_index()
      |> Enum.find_value(:ok, fn {{arg, type}, pos} ->
        case Check.check(arg, type) do
          :ok -> nil
          {:error, _} -> {:error, Violation.argument_type(state, message, pos, type, arg)}
        end
      end)
    end
  end

  defp check_message_types(_message, _transition, _state), do: :ok

  # -- Guard Evaluation --

  defp evaluate_guard(nil, _message, _tracks), do: :ok

  defp evaluate_guard(%{fun: guard_fn}, message, tracks) do
    if guard_fn.(message, tracks) do
      :ok
    else
      {:error, :guard_failed}
    end
  end

  # -- Update Application --

  defp apply_update(nil, _message, _reply, tracks), do: tracks

  defp apply_update(%{fun: update_fn}, message, reply, tracks) do
    update_fn.(message, reply, tracks)
  end

  # -- Violation Handling --

  defp handle_violation(violation, from, _state, data) do
    case data.violation_policy do
      :log ->
        log_violation(violation)
        {:keep_state, data, [{:reply, from, {:accord_violation, violation}}]}

      :reject ->
        log_violation(violation)
        {:keep_state, data, [{:reply, from, {:accord_violation, violation}}]}

      :crash ->
        {:stop_and_reply, {:protocol_violation, violation},
         [{:reply, from, {:accord_violation, violation}}]}

      {mod, fun} ->
        apply(mod, fun, [violation])
        {:keep_state, data, [{:reply, from, {:accord_violation, violation}}]}
    end
  end

  defp handle_cast_violation(violation, _state, data) do
    case data.violation_policy do
      :crash ->
        {:stop, {:protocol_violation, violation}, data}

      _ ->
        log_violation(violation)
        {:keep_state, data}
    end
  end

  defp log_violation(violation) do
    require Logger

    Logger.warning(
      "protocol violation: #{violation.kind} (#{violation.blame}) in state :#{violation.state} — #{inspect(violation.message)}"
    )
  end

  defp valid_tags(table, state) do
    table.table
    |> Enum.filter(fn {{s, _tag}, _t} -> s == state end)
    |> Enum.map(fn {{_s, tag}, _t} -> tag end)
  end
end
