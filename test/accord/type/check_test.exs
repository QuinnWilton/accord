defmodule Accord.Type.CheckTest do
  use ExUnit.Case, async: true

  alias Accord.Type.Check

  describe "check/2 — primitive types" do
    test "term matches anything" do
      assert :ok = Check.check(42, :term)
      assert :ok = Check.check("hello", :term)
      assert :ok = Check.check(:atom, :term)
      assert :ok = Check.check(nil, :term)
      assert :ok = Check.check([1, 2], :term)
    end

    test "string matches binaries" do
      assert :ok = Check.check("hello", :string)
      assert :ok = Check.check("", :string)
      assert {:error, {:type_mismatch, _}} = Check.check(42, :string)
      assert {:error, {:type_mismatch, _}} = Check.check(:atom, :string)
    end

    test "integer matches integers" do
      assert :ok = Check.check(42, :integer)
      assert :ok = Check.check(0, :integer)
      assert :ok = Check.check(-5, :integer)
      assert {:error, {:type_mismatch, _}} = Check.check(1.0, :integer)
      assert {:error, {:type_mismatch, _}} = Check.check("42", :integer)
    end

    test "pos_integer matches positive integers only" do
      assert :ok = Check.check(1, :pos_integer)
      assert :ok = Check.check(100, :pos_integer)
      assert {:error, {:type_mismatch, _}} = Check.check(0, :pos_integer)
      assert {:error, {:type_mismatch, _}} = Check.check(-1, :pos_integer)
      assert {:error, {:type_mismatch, _}} = Check.check(1.5, :pos_integer)
    end

    test "non_neg_integer matches zero and positive integers" do
      assert :ok = Check.check(0, :non_neg_integer)
      assert :ok = Check.check(42, :non_neg_integer)
      assert {:error, {:type_mismatch, _}} = Check.check(-1, :non_neg_integer)
    end

    test "atom matches atoms" do
      assert :ok = Check.check(:foo, :atom)
      assert :ok = Check.check(nil, :atom)
      assert :ok = Check.check(true, :atom)
      assert {:error, {:type_mismatch, _}} = Check.check("foo", :atom)
    end

    test "binary matches binaries" do
      assert :ok = Check.check("hello", :binary)
      assert :ok = Check.check(<<0, 1, 2>>, :binary)
      assert {:error, {:type_mismatch, _}} = Check.check(42, :binary)
    end

    test "boolean matches true and false only" do
      assert :ok = Check.check(true, :boolean)
      assert :ok = Check.check(false, :boolean)
      assert {:error, {:type_mismatch, _}} = Check.check(:true_ish, :boolean)
      assert {:error, {:type_mismatch, _}} = Check.check(1, :boolean)
    end

    test "map matches maps" do
      assert :ok = Check.check(%{}, :map)
      assert :ok = Check.check(%{a: 1}, :map)
      assert {:error, {:type_mismatch, _}} = Check.check([], :map)
    end
  end

  describe "check/2 — literal" do
    test "matches exact value" do
      assert :ok = Check.check(:ok, {:literal, :ok})
      assert :ok = Check.check(42, {:literal, 42})
      assert {:error, {:type_mismatch, _}} = Check.check(:error, {:literal, :ok})
      assert {:error, {:type_mismatch, _}} = Check.check(43, {:literal, 42})
    end
  end

  describe "check/2 — list" do
    test "matches homogeneous lists" do
      assert :ok = Check.check([1, 2, 3], {:list, :integer})
      assert :ok = Check.check([], {:list, :integer})
      assert :ok = Check.check(["a", "b"], {:list, :string})
    end

    test "rejects non-list values" do
      assert {:error, {:type_mismatch, _}} = Check.check(:atom, {:list, :integer})
    end

    test "reports element index on mismatch" do
      assert {:error, {:list_element, index: 1, reason: _}} =
               Check.check([1, "two", 3], {:list, :integer})
    end
  end

  describe "check/2 — tuple" do
    test "matches tuples with correct element types" do
      assert :ok = Check.check({:ok, 42}, {:tuple, [{:literal, :ok}, :integer]})
      assert :ok = Check.check({1, "two", :three}, {:tuple, [:integer, :string, :atom]})
    end

    test "rejects wrong size" do
      assert {:error, {:tuple_size_mismatch, expected: 2, got: 3}} =
               Check.check({1, 2, 3}, {:tuple, [:integer, :integer]})
    end

    test "reports element index on mismatch" do
      assert {:error, {:tuple_element, index: 1, reason: _}} =
               Check.check({:ok, "not_int"}, {:tuple, [{:literal, :ok}, :integer]})
    end

    test "rejects non-tuple values" do
      assert {:error, {:type_mismatch, _}} = Check.check([1, 2], {:tuple, [:integer, :integer]})
    end
  end

  describe "check/2 — struct" do
    test "matches correct struct type" do
      assert :ok = Check.check(%URI{}, {:struct, URI})
    end

    test "rejects wrong struct type" do
      assert {:error, {:type_mismatch, _}} = Check.check(%URI{}, {:struct, Range})
    end

    test "rejects non-struct values" do
      assert {:error, {:type_mismatch, _}} = Check.check(%{}, {:struct, URI})
    end
  end

  describe "check/2 — union" do
    test "matches any variant" do
      union = {:union, [:integer, :string]}
      assert :ok = Check.check(42, union)
      assert :ok = Check.check("hello", union)
      assert {:error, {:no_matching_union_type, _}} = Check.check(:atom, union)
    end
  end

  describe "check/2 — tagged" do
    test "matches tagged tuple with single payload" do
      assert :ok = Check.check({:ok, 42}, {:tagged, :ok, :integer})
      assert {:error, {:type_mismatch, _}} = Check.check({:error, 42}, {:tagged, :ok, :integer})
    end

    test "matches tagged tuple with multiple payload types" do
      assert :ok = Check.check({:ok, 42, "msg"}, {:tagged, :ok, [:integer, :string]})
    end

    test "rejects wrong tag" do
      assert {:error, {:type_mismatch, _}} =
               Check.check({:error, "reason"}, {:tagged, :ok, :string})
    end

    test "rejects wrong arity" do
      assert {:error, {:tuple_size_mismatch, _}} =
               Check.check({:ok, 1, 2}, {:tagged, :ok, :integer})
    end

    test "rejects non-tuple" do
      assert {:error, {:type_mismatch, _}} = Check.check(:ok, {:tagged, :ok, :integer})
    end
  end

  describe "check_message/2" do
    test "matches atom pattern" do
      assert :ok = Check.check_message(:ping, :ping)
      assert {:error, {:pattern_mismatch, _}} = Check.check_message(:pong, :ping)
    end

    test "matches tuple pattern with typed args" do
      pattern = {:increment, :pos_integer}
      assert :ok = Check.check_message({:increment, 5}, pattern)
    end

    test "rejects wrong argument type" do
      pattern = {:increment, :pos_integer}

      assert {:error, {:argument, 0, :pos_integer, -1}} =
               Check.check_message({:increment, -1}, pattern)
    end

    test "rejects wrong tag" do
      assert {:error, {:tag_mismatch, _}} =
               Check.check_message({:decrement, 5}, {:increment, :pos_integer})
    end

    test "rejects wrong arity" do
      assert {:error, {:arity_mismatch, _}} =
               Check.check_message({:increment, 1, 2}, {:increment, :pos_integer})
    end

    test "rejects mismatched shapes" do
      assert {:error, {:pattern_mismatch, _}} = Check.check_message(:ping, {:ping, :integer})
    end
  end

  describe "check_reply/2" do
    test "matches first valid branch" do
      branches = [
        {{:literal, :pong}, :ready},
        {:integer, :counting}
      ]

      assert {:ok, :ready} = Check.check_reply(:pong, branches)
      assert {:ok, :counting} = Check.check_reply(42, branches)
    end

    test "returns error when no branch matches" do
      branches = [{:integer, :ready}]
      assert {:error, {:no_matching_reply, _}} = Check.check_reply("string", branches)
    end

    test "returns first matching branch when multiple could match" do
      branches = [
        {:term, :first},
        {:integer, :second}
      ]

      assert {:ok, :first} = Check.check_reply(42, branches)
    end
  end
end
