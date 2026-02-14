defmodule Accord.Test.ForbiddenFail.Protocol do
  @moduledoc """
  Failure fixture: forbidden state violation.

  Tracks `:level` set from the reply value. The `forbidden` check says
  `level >= 3` must never happen, but the reply domain (0..3) allows it.
  """
  use Accord.Protocol

  initial :ready

  track :level, :non_neg_integer, default: 0

  state :ready do
    on {:set_level, value :: non_neg_integer()} do
      reply {:ok, non_neg_integer()}
      goto :ready
      update fn _msg, {:ok, v}, tracks -> %{tracks | level: v} end
    end

    on :stop, reply: :stopped, goto: :stopped
  end

  state :stopped, terminal: true

  property :no_high_level do
    forbidden fn tracks -> tracks.level >= 3 end
  end
end
