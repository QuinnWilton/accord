defmodule Accord.Test.InvariantFail.Protocol do
  @moduledoc """
  Failure fixture: global invariant violation.

  Tracks `:count` set from the reply value. The invariant says `count <= 2`
  but the reply domain includes 0..3, so TLC finds a state where count = 3.
  """
  use Accord.Protocol

  initial :ready

  track :count, :non_neg_integer, default: 0

  state :ready do
    on {:set, value :: non_neg_integer()} do
      reply {:ok, non_neg_integer()}
      goto :ready
      update fn _msg, {:ok, v}, tracks -> %{tracks | count: v} end
    end

    on :stop, reply: :stopped, goto: :stopped
  end

  state :stopped, terminal: true

  property :count_limit do
    invariant fn tracks -> tracks.count <= 2 end
  end
end
