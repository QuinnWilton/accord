defmodule Accord.Test.BoundedFail.Protocol do
  @moduledoc """
  Failure fixture: bounded invariant violation.

  Tracks `:count` incremented by 1 on each `:tick`. The `bounded` check
  limits count to max 2, but the protocol can reach count = 3.
  """
  use Accord.Protocol

  initial :running

  track :count, :non_neg_integer, default: 0

  state :running do
    on :tick do
      reply {:ok, non_neg_integer()}
      goto :running
      update fn _msg, _reply, tracks -> %{tracks | count: tracks.count + 1} end
    end

    on :stop, reply: :stopped, goto: :stopped
  end

  state :stopped, terminal: true

  property :count_bounded do
    bounded :count, max: 2
  end
end
