defmodule Accord.Test.CorrespondenceFail.Protocol do
  @moduledoc """
  Failure fixture: correspondence violation.

  The `:borrow` transition opens a correspondence (idle → active).
  The `:return` transition closes it (active → idle). But `:idle` also
  has a `:return` that goes to `:returned` — this close fires without
  a prior open, causing the correspondence counter to go negative.
  """
  use Accord.Protocol

  initial :idle

  state :idle do
    on :borrow, reply: :ok, goto: :active
    on :return, reply: :ok, goto: :returned
    on :stop, reply: :stopped, goto: :stopped
  end

  state :active do
    on :return, reply: :ok, goto: :idle
    on :stop, reply: :stopped, goto: :stopped
  end

  state :returned do
    on :stop, reply: :stopped, goto: :stopped
  end

  state :stopped, terminal: true

  property :borrow_return do
    correspondence :borrow, [:return]
  end
end
