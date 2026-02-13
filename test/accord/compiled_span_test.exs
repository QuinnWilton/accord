defmodule Accord.CompiledSpanTest do
  @moduledoc """
  Walks every component of compiled test protocols and asserts that
  each span resolves to the expected source text.

  This is the primary test for span correctness. It catches regressions
  in span capture (macros) and span refinement (RefineSpans pass).
  """
  use ExUnit.Case, async: true

  alias Accord.Test.SpanHelper
  alias Pentiment.Span.{Position, Search}

  # -- Helpers --

  defp source_for(ir) do
    Pentiment.Source.from_file(ir.source_file)
  end

  defp find_transition(ir, state_name, tag) do
    transitions = ir.states[state_name].transitions

    Enum.find(transitions, fn t ->
      case t.message_pattern do
        ^tag -> true
        tuple when is_tuple(tuple) -> elem(tuple, 0) == tag
        _ -> false
      end
    end)
  end

  defp find_anystate_transition(ir, tag) do
    Enum.find(ir.anystate, fn t ->
      case t.message_pattern do
        ^tag -> true
        tuple when is_tuple(tuple) -> elem(tuple, 0) == tag
        _ -> false
      end
    end)
  end

  defp find_property(ir, name) do
    Enum.find(ir.properties, &(&1.name == name))
  end

  # -- Lock Protocol --

  describe "Lock protocol — states" do
    setup do
      ir = Accord.Test.Lock.Protocol.__ir__()
      %{ir: ir, source: source_for(ir)}
    end

    test "state spans resolve to name atoms", %{ir: ir, source: source} do
      assert %Position{} = ir.states[:unlocked].span
      assert SpanHelper.resolve_text(ir.states[:unlocked].span, source) == ":unlocked"

      assert %Position{} = ir.states[:locked].span
      assert SpanHelper.resolve_text(ir.states[:locked].span, source) == ":locked"

      assert %Position{} = ir.states[:stopped].span
      assert SpanHelper.resolve_text(ir.states[:stopped].span, source) == ":stopped"
    end
  end

  describe "Lock protocol — tracks" do
    setup do
      ir = Accord.Test.Lock.Protocol.__ir__()
      %{ir: ir, source: source_for(ir)}
    end

    test "track spans resolve to name atoms", %{ir: ir, source: source} do
      holder = Enum.find(ir.tracks, &(&1.name == :holder))
      assert %Search{} = holder.span
      assert SpanHelper.resolve_text(holder.span, source) == ":holder"

      fence = Enum.find(ir.tracks, &(&1.name == :fence_token))
      assert %Search{} = fence.span
      assert SpanHelper.resolve_text(fence.span, source) == ":fence_token"
    end
  end

  describe "Lock protocol — transitions" do
    setup do
      ir = Accord.Test.Lock.Protocol.__ir__()
      %{ir: ir, source: source_for(ir)}
    end

    test "block form transitions resolve to full message spec", %{ir: ir, source: source} do
      acquire = find_transition(ir, :unlocked, :acquire)
      assert %Search{} = acquire.span
      assert SpanHelper.resolve_text(acquire.span, source) == "{:acquire, client_id :: term()}"

      release = find_transition(ir, :locked, :release)
      assert %Search{} = release.span
      assert SpanHelper.resolve_text(release.span, source) == "{:release, token :: pos_integer()}"
    end

    test "keyword form transitions resolve to message spec", %{ir: ir, source: source} do
      stop = find_transition(ir, :unlocked, :stop)
      assert %Search{} = stop.span
      assert SpanHelper.resolve_text(stop.span, source) == ":stop"
    end

    test "anystate transitions resolve to message spec", %{ir: ir, source: source} do
      ping = find_anystate_transition(ir, :ping)
      assert %Search{} = ping.span
      assert SpanHelper.resolve_text(ping.span, source) == ":ping"
    end

    test "cast transitions resolve to message spec", %{ir: ir, source: source} do
      heartbeat = find_anystate_transition(ir, :heartbeat)
      assert %Search{} = heartbeat.span
      assert SpanHelper.resolve_text(heartbeat.span, source) == ":heartbeat"
    end
  end

  describe "Lock protocol — branches" do
    setup do
      ir = Accord.Test.Lock.Protocol.__ir__()
      %{ir: ir, source: source_for(ir)}
    end

    test "reply macro branches resolve to reply type spec", %{ir: ir, source: source} do
      acquire = find_transition(ir, :unlocked, :acquire)
      [branch] = acquire.branches
      assert %Search{} = branch.span
      assert SpanHelper.resolve_text(branch.span, source) == "{:ok, pos_integer()}"
    end

    test "branch macro branches resolve to reply type spec", %{ir: ir, source: source} do
      release = find_transition(ir, :locked, :release)
      [ok_branch, error_branch] = release.branches

      assert %Search{} = ok_branch.span
      assert SpanHelper.resolve_text(ok_branch.span, source) == ":ok"

      assert %Search{} = error_branch.span
      assert SpanHelper.resolve_text(error_branch.span, source) == "{:error, :invalid_token}"
    end

    test "keyword form branches resolve to reply type spec", %{ir: ir, source: source} do
      stop = find_transition(ir, :unlocked, :stop)
      [branch] = stop.branches
      assert %Search{} = branch.span
      assert SpanHelper.resolve_text(branch.span, source) == ":stopped"
    end
  end

  describe "Lock protocol — arg type spans" do
    setup do
      ir = Accord.Test.Lock.Protocol.__ir__()
      %{ir: ir, source: source_for(ir)}
    end

    test "typed message args have spans resolving to type annotation", %{ir: ir, source: source} do
      acquire = find_transition(ir, :unlocked, :acquire)
      [arg_span] = acquire.message_arg_spans
      assert %Search{} = arg_span
      assert SpanHelper.resolve_text(arg_span, source) == "term()"

      release = find_transition(ir, :locked, :release)
      [arg_span] = release.message_arg_spans
      assert %Search{} = arg_span
      assert SpanHelper.resolve_text(arg_span, source) == "pos_integer()"
    end
  end

  describe "Lock protocol — properties" do
    setup do
      ir = Accord.Test.Lock.Protocol.__ir__()
      %{ir: ir, source: source_for(ir)}
    end

    test "property spans resolve to name atoms", %{ir: ir, source: source} do
      for prop <- ir.properties do
        assert %Search{} = prop.span,
               "expected Search span for property #{inspect(prop.name)}"

        assert SpanHelper.resolve_text(prop.span, source) == inspect(prop.name),
               "property #{inspect(prop.name)} span resolved to wrong text"
      end
    end
  end

  describe "Lock protocol — checks" do
    setup do
      ir = Accord.Test.Lock.Protocol.__ir__()
      %{ir: ir, source: source_for(ir)}
    end

    test "check spans resolve to check keyword", %{ir: ir, source: source} do
      for prop <- ir.properties, check <- prop.checks do
        assert %Search{} = check.span,
               "expected Search span for #{inspect(prop.name)}/#{check.kind} check"

        expected = check_keyword(check.kind)

        assert SpanHelper.resolve_text(check.span, source) == expected,
               "#{inspect(prop.name)}/#{check.kind} check span resolved to wrong text"
      end
    end

    defp check_keyword(:local_invariant), do: "invariant"
    defp check_keyword(:invariant), do: "invariant"
    defp check_keyword(:action), do: "action"
    defp check_keyword(:liveness), do: "liveness"
    defp check_keyword(:correspondence), do: "correspondence"
    defp check_keyword(:bounded), do: "bounded"
    defp check_keyword(:ordered), do: "ordered"
    defp check_keyword(:precedence), do: "precedence"
    defp check_keyword(:reachable), do: "reachable"
    defp check_keyword(:forbidden), do: "forbidden"
  end

  describe "Lock protocol — next_state_span" do
    setup do
      ir = Accord.Test.Lock.Protocol.__ir__()
      %{ir: ir, source: source_for(ir)}
    end

    test "block goto captures next_state_span", %{ir: ir, source: source} do
      acquire = find_transition(ir, :unlocked, :acquire)
      [branch] = acquire.branches
      assert %Search{} = branch.next_state_span
      assert SpanHelper.resolve_text(branch.next_state_span, source) == ":locked"
    end

    test "keyword goto captures next_state_span", %{ir: ir, source: source} do
      stop = find_transition(ir, :unlocked, :stop)
      [branch] = stop.branches
      assert %Search{} = branch.next_state_span
      assert SpanHelper.resolve_text(branch.next_state_span, source) == ":stopped"
    end

    test "branch macro captures next_state_span", %{ir: ir, source: source} do
      release = find_transition(ir, :locked, :release)
      [ok_branch, error_branch] = release.branches
      assert %Search{} = ok_branch.next_state_span
      assert SpanHelper.resolve_text(ok_branch.next_state_span, source) == ":unlocked"
      assert %Search{} = error_branch.next_state_span
      assert SpanHelper.resolve_text(error_branch.next_state_span, source) == ":locked"
    end

    test "anystate branches have nil next_state_span", %{ir: ir} do
      ping = find_anystate_transition(ir, :ping)
      [branch] = ping.branches
      assert branch.next_state_span == nil
    end
  end

  # -- Counter Protocol --

  describe "Counter protocol — states" do
    setup do
      ir = Accord.Test.Counter.Protocol.__ir__()
      %{ir: ir, source: source_for(ir)}
    end

    test "state spans resolve to name atoms", %{ir: ir, source: source} do
      assert SpanHelper.resolve_text(ir.states[:ready].span, source) == ":ready"
      assert SpanHelper.resolve_text(ir.states[:stopped].span, source) == ":stopped"
    end
  end

  describe "Counter protocol — transitions" do
    setup do
      ir = Accord.Test.Counter.Protocol.__ir__()
      %{ir: ir, source: source_for(ir)}
    end

    test "keyword tuple transitions resolve to full message spec", %{ir: ir, source: source} do
      increment = find_transition(ir, :ready, :increment)

      assert SpanHelper.resolve_text(increment.span, source) ==
               "{:increment, amount :: pos_integer()}"

      decrement = find_transition(ir, :ready, :decrement)

      assert SpanHelper.resolve_text(decrement.span, source) ==
               "{:decrement, amount :: pos_integer()}"
    end

    test "keyword atom transitions resolve to message spec", %{ir: ir, source: source} do
      get = find_transition(ir, :ready, :get)
      assert SpanHelper.resolve_text(get.span, source) == ":get"

      reset = find_transition(ir, :ready, :reset)
      assert SpanHelper.resolve_text(reset.span, source) == ":reset"

      stop = find_transition(ir, :ready, :stop)
      assert SpanHelper.resolve_text(stop.span, source) == ":stop"
    end

    test "anystate transitions resolve correctly", %{ir: ir, source: source} do
      ping = find_anystate_transition(ir, :ping)
      assert SpanHelper.resolve_text(ping.span, source) == ":ping"

      heartbeat = find_anystate_transition(ir, :heartbeat)
      assert SpanHelper.resolve_text(heartbeat.span, source) == ":heartbeat"
    end
  end

  describe "Counter protocol — branches" do
    setup do
      ir = Accord.Test.Counter.Protocol.__ir__()
      %{ir: ir, source: source_for(ir)}
    end

    test "keyword form branches resolve to reply type spec", %{ir: ir, source: source} do
      increment = find_transition(ir, :ready, :increment)
      [branch] = increment.branches
      assert SpanHelper.resolve_text(branch.span, source) == "{:ok, integer()}"

      get = find_transition(ir, :ready, :get)
      [branch] = get.branches
      assert SpanHelper.resolve_text(branch.span, source) == "{:value, integer()}"

      stop = find_transition(ir, :ready, :stop)
      [branch] = stop.branches
      assert SpanHelper.resolve_text(branch.span, source) == ":stopped"
    end

    test "anystate branch resolves to reply type spec", %{ir: ir, source: source} do
      ping = find_anystate_transition(ir, :ping)
      [branch] = ping.branches
      assert SpanHelper.resolve_text(branch.span, source) == ":pong"
    end
  end

  describe "Counter protocol — arg type spans" do
    setup do
      ir = Accord.Test.Counter.Protocol.__ir__()
      %{ir: ir, source: source_for(ir)}
    end

    test "typed message args resolve to type annotation", %{ir: ir, source: source} do
      increment = find_transition(ir, :ready, :increment)
      [arg_span] = increment.message_arg_spans
      assert SpanHelper.resolve_text(arg_span, source) == "pos_integer()"

      decrement = find_transition(ir, :ready, :decrement)
      [arg_span] = decrement.message_arg_spans
      assert SpanHelper.resolve_text(arg_span, source) == "pos_integer()"
    end
  end

  # -- Blackjack Protocol --

  describe "Blackjack protocol — states" do
    setup do
      ir = Accord.Test.Blackjack.Protocol.__ir__()
      %{ir: ir, source: source_for(ir)}
    end

    test "state spans resolve to name atoms", %{ir: ir, source: source} do
      assert SpanHelper.resolve_text(ir.states[:waiting].span, source) == ":waiting"
      assert SpanHelper.resolve_text(ir.states[:player_turn].span, source) == ":player_turn"
      assert SpanHelper.resolve_text(ir.states[:dealer_turn].span, source) == ":dealer_turn"
      assert SpanHelper.resolve_text(ir.states[:resolved].span, source) == ":resolved"
    end
  end

  describe "Blackjack protocol — tracks" do
    setup do
      ir = Accord.Test.Blackjack.Protocol.__ir__()
      %{ir: ir, source: source_for(ir)}
    end

    test "track spans resolve to name atoms", %{ir: ir, source: source} do
      balance = Enum.find(ir.tracks, &(&1.name == :balance))
      assert SpanHelper.resolve_text(balance.span, source) == ":balance"

      bet = Enum.find(ir.tracks, &(&1.name == :current_bet))
      assert SpanHelper.resolve_text(bet.span, source) == ":current_bet"
    end
  end

  describe "Blackjack protocol — transitions" do
    setup do
      ir = Accord.Test.Blackjack.Protocol.__ir__()
      %{ir: ir, source: source_for(ir)}
    end

    test "block form transitions resolve to message spec", %{ir: ir, source: source} do
      bet = find_transition(ir, :waiting, :bet)
      assert SpanHelper.resolve_text(bet.span, source) == "{:bet, chips :: pos_integer()}"

      hit = find_transition(ir, :player_turn, :hit)
      assert SpanHelper.resolve_text(hit.span, source) == ":hit"

      reveal = find_transition(ir, :dealer_turn, :reveal)
      assert SpanHelper.resolve_text(reveal.span, source) == ":reveal"
    end

    test "keyword form transitions resolve to message spec", %{ir: ir, source: source} do
      stand = find_transition(ir, :player_turn, :stand)
      assert SpanHelper.resolve_text(stand.span, source) == ":stand"
    end

    test "anystate transitions resolve to message spec", %{ir: ir, source: source} do
      balance = find_anystate_transition(ir, :balance)
      assert SpanHelper.resolve_text(balance.span, source) == ":balance"
    end
  end

  describe "Blackjack protocol — branches" do
    setup do
      ir = Accord.Test.Blackjack.Protocol.__ir__()
      %{ir: ir, source: source_for(ir)}
    end

    test "branch macro branches resolve to reply type spec", %{ir: ir, source: source} do
      bet = find_transition(ir, :waiting, :bet)
      [ok_branch] = bet.branches
      assert SpanHelper.resolve_text(ok_branch.span, source) == "{:ok, non_neg_integer()}"

      hit = find_transition(ir, :player_turn, :hit)
      [card_branch, bust_branch] = hit.branches
      assert SpanHelper.resolve_text(card_branch.span, source) == "{:card, integer()}"
      assert SpanHelper.resolve_text(bust_branch.span, source) == "{:bust, integer()}"

      reveal = find_transition(ir, :dealer_turn, :reveal)
      [pw, dw, push] = reveal.branches
      assert SpanHelper.resolve_text(pw.span, source) == "{:player_wins, non_neg_integer()}"
      assert SpanHelper.resolve_text(dw.span, source) == "{:dealer_wins, non_neg_integer()}"
      assert SpanHelper.resolve_text(push.span, source) == "{:push, non_neg_integer()}"
    end

    test "keyword form branch resolves to reply type spec", %{ir: ir, source: source} do
      stand = find_transition(ir, :player_turn, :stand)
      [branch] = stand.branches
      assert SpanHelper.resolve_text(branch.span, source) == "{:stood, integer()}"
    end

    test "anystate branch resolves to reply type spec", %{ir: ir, source: source} do
      balance = find_anystate_transition(ir, :balance)
      [branch] = balance.branches
      assert SpanHelper.resolve_text(branch.span, source) == "non_neg_integer()"
    end
  end

  describe "Blackjack protocol — guards" do
    setup do
      ir = Accord.Test.Blackjack.Protocol.__ir__()
      %{ir: ir, source: source_for(ir)}
    end

    test "guard span resolves to guard keyword", %{ir: ir, source: source} do
      bet = find_transition(ir, :waiting, :bet)
      assert %Search{} = bet.guard.span
      assert SpanHelper.resolve_text(bet.guard.span, source) == "guard"
    end
  end

  describe "Blackjack protocol — arg type spans" do
    setup do
      ir = Accord.Test.Blackjack.Protocol.__ir__()
      %{ir: ir, source: source_for(ir)}
    end

    test "typed message args resolve to type annotation", %{ir: ir, source: source} do
      bet = find_transition(ir, :waiting, :bet)
      [arg_span] = bet.message_arg_spans
      assert SpanHelper.resolve_text(arg_span, source) == "pos_integer()"
    end
  end

  describe "Blackjack protocol — properties" do
    setup do
      ir = Accord.Test.Blackjack.Protocol.__ir__()
      %{ir: ir, source: source_for(ir)}
    end

    test "property span resolves to name atom", %{ir: ir, source: source} do
      solvent = find_property(ir, :solvent)
      assert SpanHelper.resolve_text(solvent.span, source) == ":solvent"
    end

    test "check span resolves to check keyword", %{ir: ir, source: source} do
      solvent = find_property(ir, :solvent)
      [check] = solvent.checks
      assert %Search{} = check.span
      assert SpanHelper.resolve_text(check.span, source) == "invariant"
    end
  end
end
