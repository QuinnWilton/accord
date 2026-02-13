defmodule Accord.TLA.ViolationReportTest do
  use ExUnit.Case, async: true

  alias Accord.TLA.ViolationReport

  @mod Accord.Test.Lock.Protocol

  setup_all do
    Code.ensure_loaded!(@mod)
    :ok
  end

  # -- Fixtures --

  defp invariant_violation do
    %{
      kind: :invariant,
      property: "MonotonicTokens",
      trace: [
        %{
          number: 1,
          action: nil,
          assignments: %{"state" => "\"unlocked\"", "fence_token" => "0"}
        },
        %{
          number: 2,
          action: "AcquireFromUnlockedToLocked",
          assignments: %{"state" => "\"locked\"", "fence_token" => "3", "holder" => "c1"}
        },
        %{
          number: 3,
          action: "ReleaseFromLockedToUnlocked",
          assignments: %{"state" => "\"unlocked\"", "fence_token" => "3", "holder" => "c1"}
        }
      ]
    }
  end

  defp action_property_violation do
    %{
      kind: :action_property,
      property: "MonotonicTokens",
      trace: [
        %{
          number: 1,
          action: nil,
          assignments: %{"state" => "\"unlocked\"", "fence_token" => "0"}
        },
        %{
          number: 2,
          action: "AcquireFromUnlockedToLocked",
          assignments: %{"state" => "\"locked\"", "fence_token" => "2"}
        }
      ]
    }
  end

  defp deadlock_violation do
    %{
      kind: :deadlock,
      property: nil,
      trace: [
        %{number: 1, action: nil, assignments: %{"state" => "\"unlocked\""}},
        %{
          number: 2,
          action: "StopFromUnlockedToStopped",
          assignments: %{"state" => "\"stopped\""}
        }
      ]
    }
  end

  # -- Tests --

  describe "invariant violation" do
    test "renders Pentiment diagnostic with property source annotation" do
      formatted = ViolationReport.format(invariant_violation(), @mod, strict: true)

      assert formatted =~ "invariant MonotonicTokens violated"
      assert formatted =~ "property defined here"
      # Trace notes are included.
      assert formatted =~ "step 1: Initial"
      assert formatted =~ "step 2: AcquireFromUnlockedToLocked"
    end
  end

  describe "action property violation" do
    test "renders Pentiment diagnostic with property source annotation" do
      formatted = ViolationReport.format(action_property_violation(), @mod, strict: true)

      assert formatted =~ "action property MonotonicTokens violated"
      assert formatted =~ "property defined here"
      assert formatted =~ "step 2: AcquireFromUnlockedToLocked"
    end
  end

  describe "deadlock violation" do
    test "renders trace notes without crashing" do
      formatted = ViolationReport.format(deadlock_violation(), @mod, strict: false)

      assert formatted =~ "deadlock reached"
      assert formatted =~ "step 1: Initial"
      assert formatted =~ "step 2: StopFromUnlockedToStopped"
    end
  end

  describe "strict mode" do
    test "raises on nil span for unknown property" do
      violation = %{
        kind: :invariant,
        property: "NonExistentProperty",
        trace: []
      }

      assert_raise ArgumentError, ~r/missing span/, fn ->
        ViolationReport.format(violation, @mod, strict: true)
      end
    end

    test "raises when module lacks __tla_span__/1" do
      violation = %{
        kind: :invariant,
        property: "SomeProperty",
        trace: []
      }

      assert_raise ArgumentError, ~r/does not export __tla_span__\/1/, fn ->
        ViolationReport.format(violation, Enum, strict: true)
      end
    end
  end

  describe "non-strict mode" do
    test "degrades gracefully for unknown property" do
      violation = %{
        kind: :invariant,
        property: "NonExistentProperty",
        trace: []
      }

      formatted = ViolationReport.format(violation, @mod, strict: false)
      assert is_binary(formatted)
      assert formatted =~ "invariant NonExistentProperty violated"
    end

    test "degrades gracefully for module without __tla_span__/1" do
      violation = %{
        kind: :invariant,
        property: "SomeProperty",
        trace: []
      }

      formatted = ViolationReport.format(violation, Enum, strict: false)
      assert is_binary(formatted)
      assert formatted =~ "invariant SomeProperty violated"
    end
  end
end
