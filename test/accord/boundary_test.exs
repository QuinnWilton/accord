defmodule Accord.BoundaryTest do
  @moduledoc """
  Architectural boundary tests for accord2.

  These tests enforce the two-pipeline architecture documented in CLAUDE.md:
  - Downward (runtime): IR -> Monitor passes -> Monitor (gen_statem)
  - Upward (verification): IR -> TLA+ passes -> TLA+ files

  The pipelines share the IR but must not cross-depend on each other.
  """

  use ExUnit.Case, async: true
  use AssertBoundary, app: :accord

  describe "pipeline isolation" do
    test "Monitor passes do not depend on TLA passes", %{boundary: boundary} do
      refute_calls(boundary,
        from: under(Accord.Pass.Monitor),
        to: under(Accord.Pass.TLA)
      )
    end

    test "TLA passes do not depend on Monitor passes", %{boundary: boundary} do
      refute_calls(boundary,
        from: under(Accord.Pass.TLA),
        to: under(Accord.Pass.Monitor)
      )
    end

    test "Monitor does not depend on TLA passes", %{boundary: boundary} do
      refute_calls(boundary,
        from: under(Accord.Monitor),
        to: under(Accord.Pass.TLA)
      )
    end

    test "TLA modules do not depend on Monitor", %{boundary: boundary} do
      refute_calls(boundary,
        from: under(Accord.TLA),
        to: under(Accord.Monitor)
      )
    end
  end

  describe "pass encapsulation" do
    test "Monitor passes are only called by Protocol", %{boundary: boundary} do
      assert_encapsulated(boundary,
        modules: under(Accord.Pass.Monitor),
        allow: [Accord.Protocol]
      )
    end

    test "TLA passes are only called by TLA.Compiler", %{boundary: boundary} do
      assert_encapsulated(boundary,
        modules: under(Accord.Pass.TLA),
        allow: [Accord.TLA.Compiler]
      )
    end
  end

  describe "IR independence" do
    test "IR does not depend on passes", %{boundary: boundary} do
      refute_calls(boundary,
        from: under(Accord.IR),
        to: under(Accord.Pass)
      )
    end

    test "IR does not depend on Monitor", %{boundary: boundary} do
      refute_calls(boundary,
        from: under(Accord.IR),
        to: under(Accord.Monitor)
      )
    end

    test "IR does not depend on TLA modules", %{boundary: boundary} do
      refute_calls(boundary,
        from: under(Accord.IR),
        to: under(Accord.TLA)
      )
    end
  end

  describe "synthesis isolation" do
    test "IR does not depend on Synthesize", %{boundary: boundary} do
      refute_calls(boundary,
        from: under(Accord.IR),
        to: under(Accord.Synthesize)
      )
    end

    test "Pass does not depend on Synthesize", %{boundary: boundary} do
      refute_calls(boundary,
        from: under(Accord.Pass),
        to: under(Accord.Synthesize)
      )
    end

    test "Monitor does not depend on Synthesize", %{boundary: boundary} do
      refute_calls(boundary,
        from: under(Accord.Monitor),
        to: under(Accord.Synthesize)
      )
    end

    test "TLA modules do not depend on Synthesize", %{boundary: boundary} do
      refute_calls(boundary,
        from: under(Accord.TLA),
        to: under(Accord.Synthesize)
      )
    end

    test "Protocol does not depend on Synthesize", %{boundary: boundary} do
      refute_calls(boundary,
        from: [Accord.Protocol],
        to: under(Accord.Synthesize)
      )
    end

    test "Violation does not depend on Synthesize", %{boundary: boundary} do
      refute_calls(boundary,
        from: under(Accord.Violation),
        to: under(Accord.Synthesize)
      )
    end
  end
end
