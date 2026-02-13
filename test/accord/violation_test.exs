defmodule Accord.ViolationTest do
  use ExUnit.Case, async: true

  alias Accord.Violation

  describe "invalid_message/3" do
    test "creates client blame with :invalid_message kind" do
      v = Violation.invalid_message(:ready, :bad_msg, [:ping, :stop])

      assert v.blame == :client
      assert v.kind == :invalid_message
      assert v.state == :ready
      assert v.message == :bad_msg
      assert v.expected == [:ping, :stop]
    end
  end

  describe "argument_type/5" do
    test "creates client blame with position context" do
      v = Violation.argument_type(:ready, {:increment, "bad"}, 0, :pos_integer, "bad")

      assert v.blame == :client
      assert v.kind == :argument_type
      assert v.state == :ready
      assert v.context.position == 0
      assert v.context.expected_type == :pos_integer
      assert v.context.actual_value == "bad"
    end
  end

  describe "guard_failed/2" do
    test "creates client blame with :guard_failed kind" do
      v = Violation.guard_failed(:locked, {:release, :wrong_client, 1})

      assert v.blame == :client
      assert v.kind == :guard_failed
      assert v.state == :locked
      assert v.message == {:release, :wrong_client, 1}
    end
  end

  describe "session_ended/2" do
    test "creates client blame with :session_ended kind" do
      v = Violation.session_ended(:stopped, :ping)

      assert v.blame == :client
      assert v.kind == :session_ended
      assert v.state == :stopped
      assert v.expected == :none
    end
  end

  describe "invalid_reply/4" do
    test "creates server blame with reply context" do
      v = Violation.invalid_reply(:ready, :ping, :wrong, [{:literal, :pong}])

      assert v.blame == :server
      assert v.kind == :invalid_reply
      assert v.reply == :wrong
      assert v.context.valid_replies == [{:literal, :pong}]
    end
  end

  describe "timeout/3,4" do
    test "defaults to server blame" do
      v = Violation.timeout(:ready, :ping, 5000)

      assert v.blame == :server
      assert v.kind == :timeout
      assert v.context.timeout_ms == 5000
    end

    test "allows custom blame" do
      v = Violation.timeout(:ready, :ping, 5000, :client)
      assert v.blame == :client
    end
  end

  describe "invariant_violated/3" do
    test "creates property blame" do
      tracks = %{fence_token: -1}
      v = Violation.invariant_violated(:locked, :monotonic_tokens, tracks)

      assert v.blame == :property
      assert v.kind == :invariant_violated
      assert v.context.property == :monotonic_tokens
      assert v.context.tracks == tracks
    end
  end

  describe "action_violated/4" do
    test "creates property blame with track snapshots" do
      old = %{fence_token: 3}
      new = %{fence_token: 1}
      v = Violation.action_violated(:locked, :monotonic, old, new)

      assert v.blame == :property
      assert v.kind == :action_violated
      assert v.context.old_tracks == old
      assert v.context.new_tracks == new
    end
  end

  describe "inspect" do
    test "renders concise representation" do
      v = Violation.invalid_message(:ready, :bad, [:ping])
      inspected = inspect(v)

      assert inspected =~ "#Accord.Violation<"
      assert inspected =~ "blame: :client"
      assert inspected =~ "kind: :invalid_message"
    end
  end
end
