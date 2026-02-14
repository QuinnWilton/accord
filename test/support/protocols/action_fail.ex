defmodule Accord.Test.ActionFail.Protocol do
  @moduledoc """
  Failure fixture: action property violation.

  Tracks `:level` set from the reply value (which can go up or down).
  The action property says the new level must be >= the old level,
  but the nondeterministic reply domain allows decreases.
  """
  use Accord.Protocol

  initial :ready

  track :level, :non_neg_integer, default: 0

  state :ready do
    on {:adjust, amount :: non_neg_integer()} do
      reply {:ok, non_neg_integer()}
      goto :ready
      update fn _msg, {:ok, v}, tracks -> %{tracks | level: v} end
    end

    on :stop, reply: :stopped, goto: :stopped
  end

  state :stopped, terminal: true

  property :monotonic_level do
    action fn old, new -> new.level >= old.level end
  end
end
