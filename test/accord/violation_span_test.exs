defmodule Accord.ViolationSpanTest do
  @moduledoc """
  Verifies that every violation type captures the correct source span.

  Property violations carry spans directly on the violation struct.
  Transition violations (client/server blame) have spans on the
  transition in the table, looked up at format time.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Accord.Monitor
  alias Accord.Monitor.TransitionTable
  alias Accord.Test.ViolationCollector

  # Lock server that returns monotonically decreasing fence tokens.
  defmodule DecreasingTokenServer do
    use GenServer

    def start_link, do: GenServer.start_link(__MODULE__, nil)

    @impl true
    def init(_), do: {:ok, %{next_token: 10}}

    @impl true
    def handle_call({:acquire, _cid}, _from, %{next_token: t} = state) do
      {:reply, {:ok, t}, %{state | next_token: t - 5}}
    end

    def handle_call({:release, _token}, _from, state), do: {:reply, :ok, state}
    def handle_call(:ping, _from, state), do: {:reply, :pong, state}
    def handle_call(:stop, _from, state), do: {:reply, :stopped, state}

    @impl true
    def handle_cast(:heartbeat, state), do: {:noreply, state}
  end

  # -- Helpers --

  defp source_line(path, line_number) do
    path |> File.read!() |> String.split("\n") |> Enum.at(line_number - 1)
  end

  defp assert_search_span_valid(span, source_path) do
    line = source_line(source_path, span.line)

    case :binary.match(line, span.pattern) do
      {offset, len} ->
        assert offset > 0, "span pattern should not be at start of line"
        assert len > 0, "span pattern should have non-zero length"

      :nomatch ->
        flunk("span pattern #{inspect(span.pattern)} not found on line #{span.line}")
    end
  end

  # -- Property violation spans --
  # These are set directly on the violation struct via property.span.

  describe "property violation spans" do
    test ":action_violated carries span of :monotonic_tokens" do
      compiled = Accord.Test.Lock.Protocol.__compiled__()
      {:ok, server} = DecreasingTokenServer.start_link()
      ViolationCollector.init()

      {:ok, monitor} =
        Monitor.start_link(compiled,
          upstream: server,
          violation_policy: {ViolationCollector, :handle}
        )

      # Acquire: token=10, fence_token 0→10. Action passes.
      assert {:ok, 10} = Monitor.call(monitor, {:acquire, :c1})
      # Release: back to unlocked, fence_token stays 10.
      assert :ok = Monitor.call(monitor, {:release, 10})
      # Acquire: token=5, fence_token 10→5. Action violated.
      assert {:ok, 5} = Monitor.call(monitor, {:acquire, :c2})

      [violation] = ViolationCollector.drain()
      assert violation.kind == :action_violated
      assert violation.context.property == :monotonic_tokens
      assert violation.context.check_kind == :action

      assert %Pentiment.Span.Search{} = violation.span
      assert violation.span.line == 64
      assert violation.span.pattern == "action"
      assert_search_span_valid(violation.span, compiled.ir.source_file)
    end

    test ":invariant_violated (local) carries span of :holder_consistency" do
      compiled = Accord.Test.Lock.Protocol.__compiled__()
      {:ok, server} = Accord.Test.Lock.Server.start_link()
      ViolationCollector.init()

      {:ok, monitor} =
        Monitor.start_link(compiled,
          upstream: server,
          violation_policy: {ViolationCollector, :handle}
        )

      # Acquire with nil client_id — update sets holder: nil in :locked state.
      # Local invariant for :locked: tracks.holder != nil → fails.
      assert {:ok, _token} = Monitor.call(monitor, {:acquire, nil})

      [violation] = ViolationCollector.drain()
      assert violation.kind == :invariant_violated
      assert violation.context.property == :holder_consistency
      assert violation.context.check_kind == :local_invariant

      assert %Pentiment.Span.Search{} = violation.span
      assert violation.span.line == 68
      assert violation.span.pattern == "invariant"
      assert_search_span_valid(violation.span, compiled.ir.source_file)
    end
  end

  # -- Transition violation spans --
  # These live on the transition in the table, not on the violation struct.

  describe "transition violation spans" do
    test ":invalid_reply — branch span points to reply declaration" do
      compiled = Accord.Test.Lock.Protocol.__compiled__()
      {:ok, faulty} = Accord.Test.FaultyServer.start_link(Accord.Test.Lock.Server)
      Accord.Test.FaultyServer.inject_fault(faulty, :wrong_reply_type)

      {:ok, monitor} =
        Monitor.start_link(compiled, upstream: faulty, violation_policy: :log)

      assert {:accord_violation, violation} = Monitor.call(monitor, {:acquire, :c1})
      assert violation.kind == :invalid_reply
      assert violation.span == nil

      {:ok, transition} =
        TransitionTable.lookup(compiled.transition_table, :unlocked, {:acquire, :c1})

      # Transition span covers the full message spec.
      assert %Pentiment.Span.Search{} = transition.span
      assert transition.span.line == 18

      # First branch carries a span pointing to the reply declaration.
      assert [branch | _] = transition.branches
      assert %Pentiment.Span.Search{} = branch.span
      assert branch.span.line == 19
      assert branch.span.pattern == "{:ok, pos_integer()}"
      assert_search_span_valid(branch.span, compiled.ir.source_file)
    end

    test ":argument_type — span points to argument type annotation" do
      compiled = Accord.Test.Counter.Protocol.__compiled__()
      {:ok, server} = Accord.Test.Counter.Server.start_link()

      {:ok, monitor} =
        Monitor.start_link(compiled, upstream: server, violation_policy: :log)

      assert {:accord_violation, violation} = Monitor.call(monitor, {:increment, "bad"})
      assert violation.kind == :argument_type
      assert violation.span == nil

      {:ok, transition} =
        TransitionTable.lookup(compiled.transition_table, :ready, {:increment, "bad"})

      # Transition span covers the full message spec.
      assert %Pentiment.Span.Search{} = transition.span
      assert transition.span.line == 13

      # Argument names are still captured.
      assert transition.message_arg_names == ["amount"]

      # Argument type spans point at the type annotation, not the name.
      assert [%Pentiment.Span.Search{} = arg_span] = transition.message_arg_spans
      assert arg_span.line == 13
      assert arg_span.pattern == "pos_integer()"

      # Report highlights the type annotation.
      formatted = Accord.Violation.Report.format(violation, compiled, strict: true)
      assert formatted =~ "pos_integer()"

      assert_search_span_valid(arg_span, compiled.ir.source_file)
    end

    test ":guard_failed — span points to guard keyword" do
      compiled = Accord.Test.Blackjack.Protocol.__compiled__()
      {:ok, server} = Accord.Test.Blackjack.Server.start_link()

      {:ok, monitor} =
        Monitor.start_link(compiled, upstream: server, violation_policy: :log)

      # Bet exceeds balance (1000) — guard rejects.
      assert {:accord_violation, violation} = Monitor.call(monitor, {:bet, 9999})
      assert violation.kind == :guard_failed
      assert violation.span == nil

      {:ok, transition} =
        TransitionTable.lookup(compiled.transition_table, :waiting, {:bet, 9999})

      # Transition span covers the full message spec.
      assert %Pentiment.Span.Search{} = transition.span
      assert transition.span.line == 17

      # Guard pair carries its own span pointing at the guard keyword (line 18).
      assert %Pentiment.Span.Search{} = transition.guard.span
      assert transition.guard.span.line == 18
      assert transition.guard.span.pattern == "guard"
      assert_search_span_valid(transition.guard.span, compiled.ir.source_file)
    end
  end

  # -- No-span violations --
  # These have no matching transition to provide a span.

  describe "violations without spans" do
    test ":invalid_message — no matching transition" do
      compiled = Accord.Test.Blackjack.Protocol.__compiled__()
      {:ok, server} = Accord.Test.Blackjack.Server.start_link()

      {:ok, monitor} =
        Monitor.start_link(compiled, upstream: server, violation_policy: :log)

      # :hit is not valid in :waiting state.
      assert {:accord_violation, violation} = Monitor.call(monitor, :hit)
      assert violation.kind == :invalid_message
      assert violation.span == nil
      assert :error = TransitionTable.lookup(compiled.transition_table, :waiting, :hit)
    end

    test ":session_ended — terminal state has no transitions" do
      compiled = Accord.Test.Counter.Protocol.__compiled__()
      {:ok, server} = Accord.Test.Counter.Server.start_link()

      {:ok, monitor} =
        Monitor.start_link(compiled, upstream: server, violation_policy: :log)

      assert :stopped = Monitor.call(monitor, :stop)
      assert {:accord_violation, violation} = Monitor.call(monitor, :ping)
      assert violation.kind == :session_ended
      assert violation.span == nil
      assert :error = TransitionTable.lookup(compiled.transition_table, :stopped, :ping)
    end
  end
end
