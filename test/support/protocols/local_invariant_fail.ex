defmodule Accord.Test.LocalInvariantFail.Protocol do
  @moduledoc """
  Failure fixture: local invariant violation.

  Transition to `:active` does not set `:level`, so it stays at default 0.
  The local invariant requires `level > 0` when in `:active`.
  """
  use Accord.Protocol

  initial :idle

  track :level, :non_neg_integer, default: 0

  state :idle do
    on :activate, reply: :ok, goto: :active
    on :stop, reply: :stopped, goto: :stopped
  end

  state :active do
    on :deactivate, reply: :ok, goto: :idle
    on :stop, reply: :stopped, goto: :stopped
  end

  state :stopped, terminal: true

  property :active_has_level do
    invariant :active, fn _msg, tracks -> tracks.level > 0 end
  end
end
