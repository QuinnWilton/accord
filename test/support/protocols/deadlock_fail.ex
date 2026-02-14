defmodule Accord.Test.DeadlockFail.Protocol do
  @moduledoc """
  Failure fixture: deadlock violation.

  Tracks `:fuel` that decrements on each `:step`. A guard blocks `:step`
  when fuel reaches 0, but `:counting` is not terminal, so TLC reports
  a deadlock.
  """
  use Accord.Protocol

  initial :counting

  track :fuel, :non_neg_integer, default: 3

  state :counting do
    on :step do
      guard fn :step, tracks -> tracks.fuel > 0 end
      reply {:ok, non_neg_integer()}
      goto :counting
      update fn _msg, _reply, tracks -> %{tracks | fuel: tracks.fuel - 1} end
    end
  end
end
