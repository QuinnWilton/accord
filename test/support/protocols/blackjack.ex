defmodule Accord.Test.Blackjack.Protocol do
  @moduledoc """
  Simplified blackjack protocol for testing branching transitions.

  Reply types determine the next state — hit can lead to :player_turn
  (still playing) or :resolved (bust), and reveal has three possible
  outcomes. Guards enforce that bets don't exceed balance.
  """
  use Accord.Protocol

  initial :waiting

  track :balance, :non_neg_integer, default: 1000
  track :current_bet, :non_neg_integer, default: 0

  state :waiting do
    on {:bet, chips :: pos_integer()} do
      guard fn {:bet, chips}, tracks -> chips <= tracks.balance end
      update fn {:bet, chips}, _reply, tracks -> %{tracks | current_bet: chips} end
      branch {:ok, non_neg_integer()}, goto: :player_turn
    end
  end

  state :player_turn do
    on :hit do
      branch {:card, integer()}, goto: :player_turn
      branch {:bust, integer()}, goto: :resolved

      update fn _msg, reply, tracks ->
        case reply do
          {:bust, _} -> %{tracks | balance: tracks.balance - tracks.current_bet}
          {:card, _} -> tracks
        end
      end
    end

    on :stand, reply: {:stood, integer()}, goto: :dealer_turn
  end

  state :dealer_turn do
    on :reveal do
      branch {:player_wins, non_neg_integer()}, goto: :resolved
      branch {:dealer_wins, non_neg_integer()}, goto: :resolved
      branch {:push, non_neg_integer()}, goto: :resolved

      update fn _msg, reply, tracks ->
        case reply do
          {:player_wins, _} -> %{tracks | balance: tracks.balance + tracks.current_bet}
          {:dealer_wins, _} -> %{tracks | balance: tracks.balance - tracks.current_bet}
          {:push, _} -> tracks
        end
      end
    end
  end

  state :resolved, terminal: true

  anystate do
    on :balance, reply: non_neg_integer()
  end

  property :solvent do
    invariant fn tracks -> tracks.balance >= 0 end
  end
end

defmodule Accord.Test.Blackjack.Server do
  @moduledoc """
  A deterministic blackjack server for testing.

  Uses a pre-configured deck of card values. The default deck cycles
  through values that produce a mix of bust and non-bust outcomes.
  """
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    deck = Keyword.get(opts, :deck, default_deck())

    {:ok,
     %{
       deck: deck,
       player_total: 0,
       balance: 1000,
       current_bet: 0
     }}
  end

  # Cycling pattern: 5,6,7,8 gives bust after 4 hits (5+6+7+8=26).
  # 3 hits (5+6+7=18) then stand gives dealer draws of 8,9 = 17, player wins.
  def default_deck do
    base = [5, 6, 7, 8, 9, 10, 3, 4, 2, 7, 8, 6, 5, 9, 10, 3, 4, 2]
    List.flatten(List.duplicate(base, 10))
  end

  @impl true
  def handle_call({:bet, chips}, _from, state) do
    new_state = %{state | current_bet: chips, player_total: 0}
    {:reply, {:ok, state.balance}, new_state}
  end

  def handle_call(:hit, _from, state) do
    [card | rest] = state.deck
    new_total = state.player_total + card
    new_state = %{state | deck: rest, player_total: new_total}

    if new_total > 21 do
      final = %{new_state | balance: new_state.balance - new_state.current_bet}
      {:reply, {:bust, new_total}, final}
    else
      {:reply, {:card, new_total}, new_state}
    end
  end

  def handle_call(:stand, _from, state) do
    {:reply, {:stood, state.player_total}, state}
  end

  def handle_call(:reveal, _from, state) do
    {dealer_total, new_deck} = draw_dealer(state.deck, 0)

    {result, new_balance} =
      cond do
        dealer_total > 21 ->
          {{:player_wins, state.current_bet}, state.balance + state.current_bet}

        state.player_total > dealer_total ->
          {{:player_wins, state.current_bet}, state.balance + state.current_bet}

        dealer_total > state.player_total ->
          {{:dealer_wins, state.current_bet}, state.balance - state.current_bet}

        true ->
          {{:push, 0}, state.balance}
      end

    {:reply, result, %{state | deck: new_deck, balance: new_balance}}
  end

  def handle_call(:balance, _from, state) do
    {:reply, state.balance, state}
  end

  @impl true
  def handle_cast(_msg, state), do: {:noreply, state}

  defp draw_dealer(deck, total) when total >= 17, do: {total, deck}
  defp draw_dealer([card | rest], total), do: draw_dealer(rest, total + card)
end
