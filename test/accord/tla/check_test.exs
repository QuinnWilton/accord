defmodule Accord.TLA.CheckTest do
  use ExUnit.Case, async: true

  import Accord.Test.TLACheck

  @moduletag :tlc
  @moduletag :tmp_dir

  describe "passing protocols" do
    test "counter passes model checking", %{tmp_dir: tmp_dir} do
      assert_passes(Accord.Test.Counter.Protocol, tmp_dir: tmp_dir)
    end

    test "lock passes model checking", %{tmp_dir: tmp_dir} do
      assert_passes(Accord.Test.Lock.Protocol, tmp_dir: tmp_dir)
    end

    test "blackjack passes model checking", %{tmp_dir: tmp_dir} do
      assert_passes(Accord.Test.Blackjack.Protocol,
        tmp_dir: tmp_dir,
        model_config_path: "test/support/protocols/blackjack_model.exs"
      )
    end
  end

  describe "invariant violations" do
    test "global invariant detects count exceeding limit", %{tmp_dir: tmp_dir} do
      assert_fails(Accord.Test.InvariantFail.Protocol, :invariant, tmp_dir: tmp_dir)
    end

    test "local invariant detects missing track setup", %{tmp_dir: tmp_dir} do
      assert_fails(Accord.Test.LocalInvariantFail.Protocol, :invariant, tmp_dir: tmp_dir)
    end

    test "bounded check detects count exceeding bound", %{tmp_dir: tmp_dir} do
      assert_fails(Accord.Test.BoundedFail.Protocol, :invariant, tmp_dir: tmp_dir)
    end

    test "forbidden check detects reachable forbidden state", %{tmp_dir: tmp_dir} do
      assert_fails(Accord.Test.ForbiddenFail.Protocol, :invariant, tmp_dir: tmp_dir)
    end

    test "correspondence detects unmatched close", %{tmp_dir: tmp_dir} do
      assert_fails(Accord.Test.CorrespondenceFail.Protocol, :invariant, tmp_dir: tmp_dir)
    end
  end

  describe "temporal violations" do
    test "liveness detects unreachable target state", %{tmp_dir: tmp_dir} do
      assert_fails(Accord.Test.LivenessFail.Protocol, :temporal, tmp_dir: tmp_dir)
    end
  end

  describe "action property violations" do
    test "action property detects non-monotonic track", %{tmp_dir: tmp_dir} do
      assert_fails(Accord.Test.ActionFail.Protocol, :action_property, tmp_dir: tmp_dir)
    end
  end

  describe "deadlock" do
    test "deadlock detects stuck non-terminal state", %{tmp_dir: tmp_dir} do
      assert_fails(Accord.Test.DeadlockFail.Protocol, :deadlock,
        tmp_dir: tmp_dir,
        check_deadlock: true
      )
    end
  end
end
