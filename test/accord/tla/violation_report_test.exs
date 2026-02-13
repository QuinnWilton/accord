defmodule Accord.TLA.ViolationReportTest.MockProtocol do
  @moduledoc false

  # Minimal mock that exports the functions ViolationReport needs.
  # No real source file, so rendering falls back to source-less output.

  def __tla_domains__ do
    %{
      "state" => ~s({"accepting", "idle"}),
      "buffer_size" => "0..3",
      "total_enqueued" => "0..3"
    }
  end

  def __tla_span__(_), do: nil

  def __ir__ do
    %{source_file: nil}
  end
end

defmodule Accord.TLA.ViolationReportTest do
  use ExUnit.Case, async: true

  alias Accord.TLA.ViolationReport

  @mod Accord.Test.Lock.Protocol
  @mock Accord.TLA.ViolationReportTest.MockProtocol

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

  describe "TLC error reports" do
    test "renders error with message" do
      violation = %{
        kind: :error,
        property: nil,
        message: "java.lang.OutOfMemoryError: Java heap space",
        trace: []
      }

      formatted = ViolationReport.format(violation, @mock)

      assert formatted =~ "TLC model checker failed"
      assert formatted =~ "OutOfMemoryError"
    end

    test "renders error without message" do
      violation = %{
        kind: :error,
        property: nil,
        message: nil,
        trace: []
      }

      formatted = ViolationReport.format(violation, @mock)

      assert formatted =~ "TLC model checker failed"
      assert formatted =~ "unrecognized output"
      assert formatted =~ "installed correctly"
    end
  end

  describe "TypeInvariant domain overflow hints" do
    test "detects overflow and suggests remediation" do
      violation = %{
        kind: :invariant,
        property: "TypeInvariant",
        trace: [
          %{
            number: 1,
            action: nil,
            assignments: %{"state" => "\"idle\"", "buffer_size" => "0", "total_enqueued" => "0"}
          },
          %{
            number: 2,
            action: "EnqueueFromIdleToAccepting",
            assignments: %{
              "state" => "\"accepting\"",
              "buffer_size" => "1",
              "total_enqueued" => "4"
            }
          }
        ]
      }

      formatted = ViolationReport.format(violation, @mock)

      assert formatted =~ "invariant TypeInvariant violated"
      assert formatted =~ "outside its domain 0..3"
      assert formatted =~ "total_enqueued"
      assert formatted =~ "has value 4"
      assert formatted =~ "widen the domain"
      assert formatted =~ ".accord_model.exs"
      assert formatted =~ "state_constraint"
    end

    test "no overflow hint when values are within set domains" do
      violation = %{
        kind: :invariant,
        property: "TypeInvariant",
        trace: [
          %{
            number: 1,
            action: nil,
            assignments: %{"state" => "\"idle\"", "buffer_size" => "2", "total_enqueued" => "3"}
          }
        ]
      }

      formatted = ViolationReport.format(violation, @mock)

      assert formatted =~ "invariant TypeInvariant violated"
      refute formatted =~ "outside its domain"
      refute formatted =~ "widen the domain"
    end

    test "no overflow hint for non-TypeInvariant violations" do
      violation = %{
        kind: :invariant,
        property: "BufferAccounting",
        trace: [
          %{
            number: 1,
            action: nil,
            assignments: %{"buffer_size" => "4", "total_enqueued" => "4"}
          }
        ]
      }

      formatted = ViolationReport.format(violation, @mock)

      assert formatted =~ "invariant BufferAccounting violated"
      refute formatted =~ "outside its domain"
      refute formatted =~ "widen the domain"
    end

    test "no overflow hint when module lacks __tla_domains__/0" do
      violation = %{
        kind: :invariant,
        property: "TypeInvariant",
        trace: [
          %{
            number: 1,
            action: nil,
            assignments: %{"counter" => "100"}
          }
        ]
      }

      # Enum doesn't export __tla_domains__/0.
      formatted = ViolationReport.format(violation, Enum, strict: false)

      assert formatted =~ "invariant TypeInvariant violated"
      refute formatted =~ "outside its domain"
    end
  end
end
