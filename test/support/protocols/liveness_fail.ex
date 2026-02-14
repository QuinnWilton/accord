defmodule Accord.Test.LivenessFail.Protocol do
  @moduledoc """
  Failure fixture: liveness (temporal) property violation.

  The `:spinning` state has a self-loop via `:spin` but no path to `:done`.
  The liveness property requires `spinning ~> done`, which fails because
  the system can spin forever.
  """
  use Accord.Protocol

  initial :spinning

  state :spinning do
    on :spin, reply: :ok, goto: :spinning
  end

  state :done, terminal: true

  property :eventually_done do
    liveness {:in_state, :spinning}, leads_to: {:in_state, :done}
  end
end
