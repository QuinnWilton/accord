defmodule Accord.Property.ExerciserTest do
  @moduledoc """
  Protocol exerciser tests for counter, lock, and blackjack servers.

  These tests verify that each server correctly conforms to its protocol
  specification by generating a mix of valid and invalid messages and
  checking that outcomes match expectations.
  """
  use ExUnit.Case, async: false
  use PropCheck

  @moduletag :property
  @moduletag :capture_log

  alias Accord.Test.ProtocolExerciser

  describe "counter" do
    @tag :property
    test "server conforms to counter protocol" do
      ProtocolExerciser.run(
        protocol: Accord.Test.Counter.Protocol,
        server: Accord.Test.Counter.Server,
        numtests: 200,
        max_commands: 30
      )
    end
  end

  describe "lock" do
    @tag :property
    test "server conforms to lock protocol" do
      ProtocolExerciser.run(
        protocol: Accord.Test.Lock.Protocol,
        server: Accord.Test.Lock.Server,
        numtests: 200,
        max_commands: 30
      )
    end
  end

  describe "blackjack" do
    @tag :property
    test "server conforms to blackjack protocol" do
      ProtocolExerciser.run(
        protocol: Accord.Test.Blackjack.Protocol,
        server: Accord.Test.Blackjack.Server,
        numtests: 200,
        max_commands: 30
      )
    end
  end
end
