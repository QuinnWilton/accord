defmodule Accord.Property.BlackjackStatemTest do
  @moduledoc """
  PropCheck.StateM test for the Blackjack protocol.

  Exercises branching transitions — the reply type determines the next
  state. Hit can branch to :player_turn or :resolved (bust), and reveal
  has three possible outcomes. Also tests guards (bet <= balance), type
  checking, and fault injection.

  The model mirrors the server's deck and player total so it can predict
  which branch the server will take. This is necessary because
  PropCheck.StateM calls `next_state` during command generation with
  symbolic (not actual) results.

  NOTE: PropCheck.StateM.ModelDSL's `defcommand` macro does not rename
  `def` clauses with `when` guards. All dispatching must use pattern
  matching or explicit cond/if inside a single clause.
  """
  use ExUnit.Case, async: false
  use PropCheck
  use PropCheck.StateM.ModelDSL

  @moduletag :property
  @moduletag :capture_log

  alias Accord.Monitor
  alias Accord.Test.Blackjack
  alias Accord.Test.FaultyServer

  # -- Model State --
  # Mirrors the server's internal state so we can predict branching outcomes.

  defstruct protocol_state: :waiting,
            balance: 1000,
            current_bet: 0,
            player_total: 0,
            deck: [],
            terminal: false,
            pending_fault: nil

  # -- PropCheck Callbacks --

  def initial_state do
    %__MODULE__{deck: Blackjack.Server.default_deck()}
  end

  # Terminal — everything is rejected.
  def command_gen(%__MODULE__{terminal: true}) do
    frequency([
      {3, {:send_after_terminal, [gen_terminal_msg()]}},
      {1, {:send_balance_after_terminal, []}}
    ])
  end

  # Fault pending — send a valid message to trigger it.
  def command_gen(%__MODULE__{pending_fault: :wrong_reply_type, protocol_state: ps, balance: bal}) do
    case ps do
      :waiting ->
        if bal > 0 do
          {:send_bet, [exactly(1)]}
        else
          # Can't trigger fault — no valid bet. Query balance instead.
          {:send_balance, []}
        end

      :player_turn ->
        oneof([{:send_hit, []}, {:send_stand, []}])

      :dealer_turn ->
        {:send_reveal, []}
    end
  end

  def command_gen(%__MODULE__{protocol_state: :waiting, balance: bal}) do
    frequency([
      {5, {:send_bet, [gen_bet(bal)]}},
      {2, {:send_bet_over_balance, [gen_over_balance(bal)]}},
      {2, {:send_bet_bad_type, [gen_bad_pos_integer()]}},
      {2, {:send_wrong_state, [oneof([:hit, :stand, :reveal])]}},
      {2, {:send_balance, []}},
      {1, {:inject_wrong_reply, []}}
    ])
  end

  def command_gen(%__MODULE__{protocol_state: :player_turn}) do
    frequency([
      {5, {:send_hit, []}},
      {3, {:send_stand, []}},
      {2, {:send_wrong_state, [oneof([{:bet, 100}, :reveal])]}},
      {2, {:send_balance, []}},
      {1, {:inject_wrong_reply, []}}
    ])
  end

  def command_gen(%__MODULE__{protocol_state: :dealer_turn}) do
    frequency([
      {5, {:send_reveal, []}},
      {2, {:send_wrong_state, [oneof([:hit, :stand, {:bet, 100}])]}},
      {2, {:send_balance, []}},
      {1, {:inject_wrong_reply, []}}
    ])
  end

  # -- Generators --

  defp gen_bet(balance) do
    if balance > 0 do
      integer(1, max(1, balance))
    else
      exactly(1)
    end
  end

  defp gen_over_balance(balance), do: integer(balance + 1, balance + 500)

  defp gen_bad_pos_integer, do: oneof([integer(-100, 0), exactly("chips"), exactly(nil)])

  defp gen_terminal_msg, do: oneof([{:bet, 100}, :hit, :stand, :reveal, :balance])

  # -- Commands --

  defcommand :send_bet do
    def impl(chips) do
      monitor = Process.get(:test_monitor)
      Monitor.call(monitor, {:bet, chips})
    end

    def pre(%__MODULE__{protocol_state: :waiting, terminal: false}, _), do: true
    def pre(_, _), do: false

    def post(%__MODULE__{balance: bal, pending_fault: fault}, [chips], result) do
      cond do
        chips > bal ->
          match?({:accord_violation, %{blame: :client, kind: :guard_failed}}, result)

        fault == :wrong_reply_type ->
          match?({:accord_violation, %{blame: :server, kind: :invalid_reply}}, result)

        true ->
          match?({:ok, _}, result)
      end
    end

    def next(%__MODULE__{balance: bal} = state, [chips], _result) do
      cond do
        chips > bal ->
          # Guard failed — state unchanged.
          state

        state.pending_fault == :wrong_reply_type ->
          # Fault consumed, no server-side state change.
          %{state | pending_fault: nil}

        true ->
          %{state | current_bet: chips, player_total: 0, protocol_state: :player_turn}
      end
    end
  end

  defcommand :send_bet_over_balance do
    def impl(chips) do
      monitor = Process.get(:test_monitor)
      Monitor.call(monitor, {:bet, chips})
    end

    def pre(%__MODULE__{protocol_state: :waiting, terminal: false}, _), do: true
    def pre(_, _), do: false

    def post(_state, [_chips], result) do
      match?({:accord_violation, %{blame: :client, kind: :guard_failed}}, result)
    end
  end

  defcommand :send_bet_bad_type do
    def impl(bad_value) do
      monitor = Process.get(:test_monitor)
      Monitor.call(monitor, {:bet, bad_value})
    end

    def pre(%__MODULE__{protocol_state: :waiting, terminal: false}, _), do: true
    def pre(_, _), do: false

    def post(_state, [_bad], result) do
      match?({:accord_violation, %{blame: :client, kind: :argument_type}}, result)
    end
  end

  defcommand :send_hit do
    def impl do
      monitor = Process.get(:test_monitor)
      Monitor.call(monitor, :hit)
    end

    def pre(%__MODULE__{protocol_state: :player_turn, terminal: false}, _), do: true
    def pre(_, _), do: false

    def post(%__MODULE__{pending_fault: fault, deck: deck, player_total: pt}, [], result) do
      if fault == :wrong_reply_type do
        match?({:accord_violation, %{blame: :server, kind: :invalid_reply}}, result)
      else
        [card | _] = deck
        new_total = pt + card

        if new_total > 21 do
          result == {:bust, new_total}
        else
          result == {:card, new_total}
        end
      end
    end

    def next(%__MODULE__{deck: deck, player_total: pt} = state, [], _result) do
      if state.pending_fault == :wrong_reply_type do
        # Fault consumed, no server-side state change.
        %{state | pending_fault: nil}
      else
        [card | rest] = deck
        new_total = pt + card

        if new_total > 21 do
          %{
            state
            | deck: rest,
              player_total: new_total,
              protocol_state: :resolved,
              terminal: true,
              balance: state.balance - state.current_bet
          }
        else
          %{state | deck: rest, player_total: new_total}
        end
      end
    end
  end

  defcommand :send_stand do
    def impl do
      monitor = Process.get(:test_monitor)
      Monitor.call(monitor, :stand)
    end

    def pre(%__MODULE__{protocol_state: :player_turn, terminal: false}, _), do: true
    def pre(_, _), do: false

    def post(%__MODULE__{pending_fault: fault, player_total: pt}, [], result) do
      if fault == :wrong_reply_type do
        match?({:accord_violation, %{blame: :server, kind: :invalid_reply}}, result)
      else
        result == {:stood, pt}
      end
    end

    def next(state, [], _result) do
      if state.pending_fault == :wrong_reply_type do
        %{state | pending_fault: nil}
      else
        %{state | protocol_state: :dealer_turn}
      end
    end
  end

  defcommand :send_reveal do
    def impl do
      monitor = Process.get(:test_monitor)
      Monitor.call(monitor, :reveal)
    end

    def pre(%__MODULE__{protocol_state: :dealer_turn, terminal: false}, _), do: true
    def pre(_, _), do: false

    def post(%__MODULE__{pending_fault: fault} = state, [], result) do
      if fault == :wrong_reply_type do
        match?({:accord_violation, %{blame: :server, kind: :invalid_reply}}, result)
      else
        {dealer_total, _} = draw_dealer_static(state.deck, 0)

        expected =
          cond do
            dealer_total > 21 -> {:player_wins, state.current_bet}
            state.player_total > dealer_total -> {:player_wins, state.current_bet}
            dealer_total > state.player_total -> {:dealer_wins, state.current_bet}
            true -> {:push, 0}
          end

        result == expected
      end
    end

    def next(state, [], _result) do
      if state.pending_fault == :wrong_reply_type do
        %{state | pending_fault: nil}
      else
        {dealer_total, new_deck} = draw_dealer_static(state.deck, 0)

        new_balance =
          cond do
            dealer_total > 21 -> state.balance + state.current_bet
            state.player_total > dealer_total -> state.balance + state.current_bet
            dealer_total > state.player_total -> state.balance - state.current_bet
            true -> state.balance
          end

        %{state | deck: new_deck, protocol_state: :resolved, terminal: true, balance: new_balance}
      end
    end
  end

  # Static helper accessible from defcommand (needs to be a module function).
  def draw_dealer_static(deck, total) when total >= 17, do: {total, deck}
  def draw_dealer_static([card | rest], total), do: draw_dealer_static(rest, total + card)

  defcommand :send_balance do
    def impl do
      monitor = Process.get(:test_monitor)
      Monitor.call(monitor, :balance)
    end

    def pre(%__MODULE__{terminal: false}, _), do: true
    def pre(_, _), do: false

    def post(_state, [], result) do
      is_integer(result) and result >= 0
    end
  end

  defcommand :send_wrong_state do
    def impl(message) do
      monitor = Process.get(:test_monitor)
      Monitor.call(monitor, message)
    end

    def pre(%__MODULE__{terminal: false}, _), do: true
    def pre(_, _), do: false

    def post(%__MODULE__{protocol_state: ps}, [msg], result) do
      tag = if is_tuple(msg), do: elem(msg, 0), else: msg

      valid_tags =
        case ps do
          :waiting -> [:bet, :balance]
          :player_turn -> [:hit, :stand, :balance]
          :dealer_turn -> [:reveal, :balance]
        end

      if tag in valid_tags do
        true
      else
        match?({:accord_violation, %{blame: :client, kind: :invalid_message}}, result)
      end
    end
  end

  defcommand :send_after_terminal do
    def impl(message) do
      monitor = Process.get(:test_monitor)
      Monitor.call(monitor, message)
    end

    def pre(%__MODULE__{terminal: true}, _), do: true
    def pre(_, _), do: false

    def post(_state, [_msg], result) do
      match?({:accord_violation, %{blame: :client, kind: :session_ended}}, result)
    end
  end

  defcommand :send_balance_after_terminal do
    def impl do
      monitor = Process.get(:test_monitor)
      Monitor.call(monitor, :balance)
    end

    def pre(%__MODULE__{terminal: true}, _), do: true
    def pre(_, _), do: false

    def post(_state, [], result) do
      match?({:accord_violation, %{blame: :client, kind: :session_ended}}, result)
    end
  end

  defcommand :inject_wrong_reply do
    def impl do
      faulty = Process.get(:test_faulty_server)
      FaultyServer.inject_fault(faulty, :wrong_reply_type)
    end

    def pre(%__MODULE__{terminal: true}, _), do: false
    def pre(%__MODULE__{pending_fault: nil}, _), do: true
    def pre(_, _), do: false

    def post(_state, [], result), do: result == :ok

    def next(state, [], _result) do
      %{state | pending_fault: :wrong_reply_type}
    end
  end

  # -- Property --

  @tag :property
  test "blackjack protocol handles branching, guards, and faults correctly" do
    result =
      quickcheck(
        forall cmds <- commands(__MODULE__) do
          Accord.Test.ViolationCollector.init()

          {:ok, faulty} = FaultyServer.start_link(Blackjack.Server)
          compiled = Blackjack.Protocol.__compiled__()

          {:ok, monitor} =
            Monitor.start_link(compiled,
              upstream: faulty,
              violation_policy: {Accord.Test.ViolationCollector, :handle}
            )

          Process.put(:test_monitor, monitor)
          Process.put(:test_faulty_server, faulty)

          {history, _state, result} = run_commands(__MODULE__, cmds)

          prop_violations = Accord.Test.ViolationCollector.property_violations()

          # Cleanup.
          if Process.alive?(monitor), do: GenServer.stop(monitor, :normal, 100)
          if Process.alive?(faulty), do: GenServer.stop(faulty, :normal, 100)

          passed = result == :ok and prop_violations == []

          unless passed do
            Process.put(
              :__accord_property_failure__,
              Accord.PropertyFailure.exception(
                history: history,
                compiled: compiled,
                violations: prop_violations
              )
            )
          end

          passed
        end,
        [:quiet, numtests: 200, max_size: 30]
      )

    unless result == true do
      raise Process.get(:__accord_property_failure__) ||
              ExUnit.AssertionError.exception(message: "Property failed")
    end
  end
end
