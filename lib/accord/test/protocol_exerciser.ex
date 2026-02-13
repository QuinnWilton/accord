defmodule Accord.Test.ProtocolExerciser do
  @moduledoc """
  Exercises a server implementation against its protocol specification.

  Generates a mix of valid and invalid messages from the protocol IR,
  sends them through a monitor, and verifies the outcome matches:
  valid messages succeed, invalid messages are rejected with the
  correct violation kind.

  ## Usage

      test "server conforms to lock protocol" do
        Accord.Test.ProtocolExerciser.run(
          protocol: Lock.Protocol,
          server: Lock.Server,
          numtests: 200,
          max_commands: 30
        )
      end
  """

  import PropCheck

  alias Accord.Monitor
  alias Accord.Monitor.TransitionTable
  alias Accord.Test.{ExerciserFailure, TypeGen, ViolationCollector}

  @type command ::
          {:valid, non_neg_integer()}
          | {:bad_type, non_neg_integer()}
          | {:wrong_state, non_neg_integer()}
          | {:guard_fail, non_neg_integer()}
          | {:unknown}

  @doc """
  Runs the protocol exerciser as a PropCheck property test.

  ## Options

  - `:protocol` (required) — the protocol module (e.g., `Lock.Protocol`).
  - `:server` (required) — the server module (e.g., `Lock.Server`).
  - `:server_args` — args passed to `server.start_link/1`. Default `[]`.
  - `:numtests` — number of PropCheck test cases. Default `200`.
  - `:max_commands` — max commands per test case. Default `30`.
  """
  @spec run(keyword()) :: :ok | no_return()
  def run(opts) do
    protocol = Keyword.fetch!(opts, :protocol)
    server = Keyword.fetch!(opts, :server)
    server_args = Keyword.get(opts, :server_args, [])
    numtests = Keyword.get(opts, :numtests, 200)
    max_commands = Keyword.get(opts, :max_commands, 30)

    compiled = protocol.__compiled__()

    # ETS table to preserve failure across shrinking runs.
    failure_table = :ets.new(:exerciser_failure, [:set, :public])

    result =
      quickcheck(
        forall cmds <- gen_commands(max_commands) do
          case execute_and_verify(compiled, server, server_args, cmds) do
            true ->
              true

            {:failure, failure} ->
              :ets.insert(failure_table, {:last_failure, failure})
              false
          end
        end,
        [:quiet, numtests: numtests, max_size: max_commands]
      )

    unless result == true do
      case :ets.lookup(failure_table, :last_failure) do
        [{:last_failure, failure}] ->
          :ets.delete(failure_table)
          raise failure

        [] ->
          :ets.delete(failure_table)
          raise ExUnit.AssertionError, message: "Protocol exerciser failed"
      end
    end

    :ets.delete(failure_table)
    :ok
  end

  # -- Command generation --

  defp gen_commands(max_commands) do
    # Generate a pair {tag, idx} where tag selects the command kind
    # and idx selects which transition to use. Simple types that
    # proper can shrink without bind/let complexity.
    cmd_gen =
      :proper_types.frequency([
        {5,
         :proper_types.fixed_list([:proper_types.exactly(:valid), :proper_types.integer(0, 1000)])},
        {2,
         :proper_types.fixed_list([
           :proper_types.exactly(:bad_type),
           :proper_types.integer(0, 1000)
         ])},
        {2,
         :proper_types.fixed_list([
           :proper_types.exactly(:wrong_state),
           :proper_types.integer(0, 1000)
         ])},
        {1,
         :proper_types.fixed_list([
           :proper_types.exactly(:guard_fail),
           :proper_types.integer(0, 1000)
         ])},
        {1, :proper_types.exactly([:unknown])}
      ])

    :proper_types.vector(max_commands, cmd_gen)
  end

  # -- Execution --

  defp execute_and_verify(compiled, server, server_args, commands) do
    ViolationCollector.init()

    {:ok, upstream} = apply(server, :start_link, [server_args])

    {:ok, monitor} =
      Monitor.start_link(compiled,
        upstream: upstream,
        violation_policy: {ViolationCollector, :handle}
      )

    table = compiled.transition_table
    steps = execute_commands(commands, monitor, table, [])

    # Check for property violations.
    prop_violations = ViolationCollector.property_violations()

    # Cleanup.
    if Process.alive?(monitor), do: GenServer.stop(monitor, :normal, 100)
    if Process.alive?(upstream), do: GenServer.stop(upstream, :normal, 100)

    failing_step = Enum.find(steps, &(not &1.passed))

    if failing_step == nil and prop_violations == [] do
      true
    else
      {:failure,
       ExerciserFailure.exception(
         steps: steps,
         property_violations: prop_violations,
         compiled: compiled
       )}
    end
  end

  defp execute_commands([], _monitor, _table, acc), do: Enum.reverse(acc)

  defp execute_commands([cmd | rest], monitor, table, acc) do
    # Query actual monitor state.
    {state, monitor_data} = :sys.get_state(monitor)
    tracks = monitor_data.tracks
    terminal = TransitionTable.terminal?(table, state)

    step = resolve_and_execute(cmd, monitor, table, state, tracks, terminal)

    if step.passed do
      execute_commands(rest, monitor, table, [step | acc])
    else
      # Stop on first mismatch.
      Enum.reverse([step | acc])
    end
  end

  # -- Command resolution and execution --

  defp resolve_and_execute([:valid, idx], monitor, table, state, tracks, terminal) do
    if terminal do
      make_step([:valid, idx], state, tracks, nil, nil, :skipped, nil, true)
    else
      transitions = transitions_for_state(table, state)

      case pick_transition(transitions, idx) do
        nil ->
          make_step([:valid, idx], state, tracks, nil, nil, :skipped, nil, true)

        transition ->
          case gen_valid_message(transition, tracks) do
            {:ok, message} ->
              expected = :ok
              result = send_message(monitor, transition.kind, message)
              passed = valid_result?(result)

              make_step(
                [:valid, idx],
                state,
                tracks,
                transition_info(transition),
                message,
                expected,
                result,
                passed
              )

            :skip ->
              make_step(
                [:valid, idx],
                state,
                tracks,
                transition_info(transition),
                nil,
                :skipped,
                nil,
                true
              )
          end
      end
    end
  end

  defp resolve_and_execute([:bad_type, idx], monitor, table, state, tracks, terminal) do
    # Collect transitions with typed args from ALL states.
    typed = all_typed_transitions(table)

    case pick_transition(typed, idx) do
      nil ->
        make_step([:bad_type, idx], state, tracks, nil, nil, :skipped, nil, true)

      transition ->
        case gen_bad_type_message(transition) do
          nil ->
            make_step(
              [:bad_type, idx],
              state,
              tracks,
              transition_info(transition),
              nil,
              :skipped,
              nil,
              true
            )

          {:ok, message} ->
            expected = classify_bad_type(table, state, terminal, message)
            result = send_message(monitor, :call, message)
            passed = outcome_matches?(expected, result)

            make_step(
              [:bad_type, idx],
              state,
              tracks,
              transition_info(transition),
              message,
              expected,
              result,
              passed
            )
        end
    end
  end

  defp resolve_and_execute([:wrong_state, idx], monitor, table, state, tracks, terminal) do
    # Transitions from states OTHER than current.
    other = transitions_from_other_states(table, state)

    case pick_transition(other, idx) do
      nil ->
        make_step([:wrong_state, idx], state, tracks, nil, nil, :skipped, nil, true)

      transition ->
        {:ok, message} = gen_valid_message_no_guard(transition)
        expected = classify_wrong_state(table, state, terminal, message)
        result = send_message(monitor, :call, message)
        passed = outcome_matches?(expected, result)

        make_step(
          [:wrong_state, idx],
          state,
          tracks,
          transition_info(transition),
          message,
          expected,
          result,
          passed
        )
    end
  end

  defp resolve_and_execute([:guard_fail, idx], monitor, table, state, tracks, terminal) do
    if terminal do
      make_step([:guard_fail, idx], state, tracks, nil, nil, :skipped, nil, true)
    else
      guarded = guarded_transitions(table, state)

      case pick_transition(guarded, idx) do
        nil ->
          make_step([:guard_fail, idx], state, tracks, nil, nil, :skipped, nil, true)

        transition ->
          case gen_guard_failing_message(transition, tracks) do
            {:ok, message} ->
              expected = {:violation, :client, :guard_failed}
              result = send_message(monitor, :call, message)
              passed = outcome_matches?(expected, result)

              make_step(
                [:guard_fail, idx],
                state,
                tracks,
                transition_info(transition),
                message,
                expected,
                result,
                passed
              )

            :skip ->
              make_step(
                [:guard_fail, idx],
                state,
                tracks,
                transition_info(transition),
                nil,
                :skipped,
                nil,
                true
              )
          end
      end
    end
  end

  defp resolve_and_execute([:unknown], monitor, _table, state, tracks, terminal) do
    message = :__exerciser_unknown_msg__

    expected =
      if terminal,
        do: {:violation, :client, :session_ended},
        else: {:violation, :client, :invalid_message}

    result = send_message(monitor, :call, message)
    passed = outcome_matches?(expected, result)

    make_step([:unknown], state, tracks, nil, message, expected, result, passed)
  end

  # -- Message sending --

  defp send_message(monitor, :call, message) do
    Monitor.call(monitor, message, 5_000)
  end

  defp send_message(monitor, :cast, message) do
    Monitor.cast(monitor, message)
    # Synchronize to ensure cast is processed.
    :sys.get_state(monitor)
    :ok
  end

  # -- Outcome classification --

  defp classify_bad_type(_table, _state, true, _message) do
    {:violation, :client, :session_ended}
  end

  defp classify_bad_type(table, state, false, message) do
    tag = TransitionTable.message_tag(message)

    case Map.fetch(table.table, {state, tag}) do
      {:ok, transition} ->
        # Check if the message actually fails type checking. Some types
        # (like :term) accept any value, so a "bad type" message may
        # still be valid.
        case check_types(message, transition) do
          :ok -> :ok_or_violation
          :type_error -> {:violation, :client, :argument_type}
        end

      :error ->
        {:violation, :client, :invalid_message}
    end
  end

  defp check_types(_message, %{message_types: []}) do
    :ok
  end

  defp check_types(message, %{message_types: types}) when is_tuple(message) do
    args = message |> Tuple.to_list() |> tl()

    if length(args) != length(types) do
      :ok
    else
      args
      |> Enum.zip(types)
      |> Enum.any?(fn {arg, type} ->
        Accord.Type.Check.check(arg, type) != :ok
      end)
      |> if(do: :type_error, else: :ok)
    end
  end

  defp check_types(_message, _transition), do: :ok

  defp classify_wrong_state(_table, _state, true, _message) do
    {:violation, :client, :session_ended}
  end

  defp classify_wrong_state(table, state, false, message) do
    # If the tag happens to be valid in the current state, it might succeed.
    case TransitionTable.lookup(table, state, message) do
      {:ok, _} -> :ok_or_violation
      :error -> {:violation, :client, :invalid_message}
    end
  end

  # -- Outcome matching --

  defp valid_result?({:accord_violation, _}), do: false
  defp valid_result?(_), do: true

  defp outcome_matches?(:ok_or_violation, _result) do
    # Wrong-state message that happens to be valid in current state.
    # Any outcome is acceptable.
    true
  end

  defp outcome_matches?({:violation, blame, kind}, {:accord_violation, %{blame: b, kind: k}}) do
    blame == b and kind == k
  end

  defp outcome_matches?({:violation, _blame, _kind}, _result), do: false

  # -- Transition helpers --

  defp transitions_for_state(table, state) do
    table.table
    |> Enum.filter(fn {{s, _tag}, _t} -> s == state end)
    |> Enum.map(fn {_key, t} -> t end)
  end

  defp all_typed_transitions(table) do
    table.table
    |> Enum.map(fn {_key, t} -> t end)
    |> Enum.filter(&(&1.message_types != [] and &1.kind == :call))
    |> Enum.uniq_by(&{&1.message_pattern, &1.message_types})
  end

  defp transitions_from_other_states(table, current_state) do
    table.table
    |> Enum.filter(fn {{s, _tag}, t} -> s != current_state and t.kind == :call end)
    |> Enum.map(fn {_key, t} -> t end)
    |> Enum.uniq_by(& &1.message_pattern)
  end

  defp guarded_transitions(table, state) do
    table.table
    |> Enum.filter(fn {{s, _tag}, t} -> s == state and t.guard != nil end)
    |> Enum.map(fn {_key, t} -> t end)
  end

  defp pick_transition([], _idx), do: nil
  defp pick_transition(transitions, idx), do: Enum.at(transitions, rem(idx, length(transitions)))

  # -- Message generation with guard sampling --

  defp gen_valid_message(transition, tracks) do
    Enum.reduce_while(1..50, :skip, fn _, _ ->
      {:ok, message} = :proper_gen.pick(TypeGen.gen_message(transition))

      if guard_passes?(transition, message, tracks) do
        {:halt, {:ok, message}}
      else
        {:cont, :skip}
      end
    end)
  end

  defp gen_valid_message_no_guard(transition) do
    {:ok, message} = :proper_gen.pick(TypeGen.gen_message(transition))
    {:ok, message}
  end

  defp gen_bad_type_message(transition) do
    case TypeGen.gen_bad_message(transition) do
      nil ->
        nil

      gen ->
        {:ok, message} = :proper_gen.pick(gen)
        {:ok, message}
    end
  end

  defp gen_guard_failing_message(transition, tracks) do
    Enum.reduce_while(1..50, :skip, fn _, _ ->
      {:ok, message} = :proper_gen.pick(TypeGen.gen_message(transition))

      if not guard_passes?(transition, message, tracks) do
        {:halt, {:ok, message}}
      else
        {:cont, :skip}
      end
    end)
  end

  defp guard_passes?(%{guard: nil}, _message, _tracks), do: true

  defp guard_passes?(%{guard: %{fun: f}}, message, tracks) do
    f.(message, tracks)
  end

  # -- Step construction --

  defp make_step(command, state, tracks, transition, message, expected, actual, passed) do
    %{
      command: command,
      state: state,
      tracks: tracks,
      transition: transition,
      message: message,
      expected: expected,
      actual: actual,
      passed: passed
    }
  end

  defp transition_info(nil), do: nil

  defp transition_info(transition) do
    %{
      pattern: transition.message_pattern,
      kind: transition.kind,
      from: transition.from
    }
  end
end
