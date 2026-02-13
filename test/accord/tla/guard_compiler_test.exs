defmodule Accord.TLA.GuardCompilerTest do
  use ExUnit.Case, async: true

  alias Accord.TLA.GuardCompiler

  describe "literals" do
    test "integer" do
      assert {:ok, "42"} = GuardCompiler.compile(42)
    end

    test "negative integer" do
      assert {:ok, "-1"} = GuardCompiler.compile(-1)
    end

    test "boolean true" do
      assert {:ok, "TRUE"} = GuardCompiler.compile(true)
    end

    test "boolean false" do
      assert {:ok, "FALSE"} = GuardCompiler.compile(false)
    end

    test "nil" do
      assert {:ok, "NULL"} = GuardCompiler.compile(nil)
    end

    test "string" do
      assert {:ok, ~s("hello")} = GuardCompiler.compile("hello")
    end
  end

  describe "variables" do
    test "bare variable" do
      ast = quote(do: x)
      assert {:ok, "x"} = GuardCompiler.compile(ast)
    end

    test "variable with binding" do
      ast = quote(do: token)
      assert {:ok, "msg_token"} = GuardCompiler.compile(ast, %{token: "msg_token"})
    end

    test "unbound variable uses atom name" do
      ast = quote(do: counter)
      assert {:ok, "counter"} = GuardCompiler.compile(ast)
    end
  end

  describe "dot access" do
    test "tracks.field compiles to field name" do
      ast = quote(do: tracks.fence_token)
      assert {:ok, "fence_token"} = GuardCompiler.compile(ast)
    end

    test "any_var.field compiles to field name" do
      ast = quote(do: state.balance)
      assert {:ok, "balance"} = GuardCompiler.compile(ast)
    end
  end

  describe "comparison operators" do
    test "greater than" do
      ast = quote(do: x > 0)
      assert {:ok, "x > 0"} = GuardCompiler.compile(ast)
    end

    test "greater than or equal" do
      ast = quote(do: x >= 0)
      assert {:ok, "x >= 0"} = GuardCompiler.compile(ast)
    end

    test "less than" do
      ast = quote(do: x < 10)
      assert {:ok, "x < 10"} = GuardCompiler.compile(ast)
    end

    test "less than or equal" do
      ast = quote(do: x <= 10)
      assert {:ok, "x =< 10"} = GuardCompiler.compile(ast)
    end

    test "equal" do
      ast = quote(do: x == y)
      assert {:ok, "x = y"} = GuardCompiler.compile(ast)
    end

    test "not equal" do
      ast = quote(do: x != y)
      assert {:ok, "x /= y"} = GuardCompiler.compile(ast)
    end
  end

  describe "arithmetic operators" do
    test "addition" do
      ast = quote(do: x + 1)
      assert {:ok, "(x + 1)"} = GuardCompiler.compile(ast)
    end

    test "subtraction" do
      ast = quote(do: x - 1)
      assert {:ok, "(x - 1)"} = GuardCompiler.compile(ast)
    end

    test "multiplication" do
      ast = quote(do: x * 2)
      assert {:ok, "(x * 2)"} = GuardCompiler.compile(ast)
    end

    test "integer division" do
      ast = quote(do: div(x, 2))
      assert {:ok, "(x \\div 2)"} = GuardCompiler.compile(ast)
    end

    test "remainder" do
      ast = quote(do: rem(x, 3))
      assert {:ok, "(x % 3)"} = GuardCompiler.compile(ast)
    end
  end

  describe "boolean operators" do
    test "and" do
      ast = quote(do: x > 0 and y > 0)
      assert {:ok, "(x > 0 /\\ y > 0)"} = GuardCompiler.compile(ast)
    end

    test "or" do
      ast = quote(do: x > 0 or y > 0)
      assert {:ok, "(x > 0 \\/ y > 0)"} = GuardCompiler.compile(ast)
    end

    test "not" do
      ast = quote(do: not x)
      assert {:ok, "~x"} = GuardCompiler.compile(ast)
    end
  end

  describe "built-in functions" do
    test "length" do
      ast = quote(do: length(items))
      assert {:ok, "Len(items)"} = GuardCompiler.compile(ast)
    end

    test "is_integer" do
      ast = quote(do: is_integer(x))
      assert {:ok, "x \\in Int"} = GuardCompiler.compile(ast)
    end

    test "is_boolean" do
      ast = quote(do: is_boolean(x))
      assert {:ok, "x \\in BOOLEAN"} = GuardCompiler.compile(ast)
    end

    test "abs" do
      ast = quote(do: abs(x))
      assert {:ok, "IF x >= 0 THEN x ELSE -(x)"} = GuardCompiler.compile(ast)
    end
  end

  describe "nested expressions" do
    test "comparison with arithmetic" do
      ast = quote(do: x + 1 > y - 2)
      assert {:ok, "(x + 1) > (y - 2)"} = GuardCompiler.compile(ast)
    end

    test "boolean with comparisons" do
      ast = quote(do: x > 0 and x < 100)
      assert {:ok, "(x > 0 /\\ x < 100)"} = GuardCompiler.compile(ast)
    end

    test "complex nested expression" do
      ast = quote(do: (x > 0 and y > 0) or z == 0)
      assert {:ok, "((x > 0 /\\ y > 0) \\/ z = 0)"} = GuardCompiler.compile(ast)
    end

    test "dot access in comparison" do
      ast = quote(do: tracks.fence_token >= 0)
      assert {:ok, "fence_token >= 0"} = GuardCompiler.compile(ast)
    end
  end

  describe "bindings" do
    test "resolves bound variables" do
      ast = quote(do: token > tracks.fence_token)
      bindings = %{token: "msg_token"}
      assert {:ok, "msg_token > fence_token"} = GuardCompiler.compile(ast, bindings)
    end

    test "multiple bindings" do
      ast = quote(do: client_id == tracks.holder and token > tracks.fence_token)
      bindings = %{client_id: "msg_client_id", token: "msg_token"}

      assert {:ok, "(msg_client_id = holder /\\ msg_token > fence_token)"} =
               GuardCompiler.compile(ast, bindings)
    end
  end

  describe "fn expressions" do
    test "extracts body from single-clause fn" do
      ast = quote(do: fn tracks -> tracks.counter >= 0 end)
      assert {:ok, "counter >= 0"} = GuardCompiler.compile(ast)
    end

    test "fn with pattern match args" do
      ast =
        quote(
          do: fn {:bet, chips}, tracks ->
            chips <= tracks.balance
          end
        )

      bindings = %{chips: "msg_chips"}

      assert {:ok, "msg_chips =< balance"} =
               GuardCompiler.compile(ast, bindings)
    end
  end

  describe "unsupported forms" do
    test "function call returns TRUE with warning" do
      ast = quote(do: String.length(x))
      assert {:partial, "TRUE", [warning]} = GuardCompiler.compile(ast)
      assert warning.message =~ "not compilable to TLA+"
    end

    test "case expression returns TRUE with warning" do
      ast =
        quote(
          do:
            case x do
              1 -> true
              _ -> false
            end
        )

      assert {:partial, "TRUE", [warning]} = GuardCompiler.compile(ast)
      assert warning.message =~ "not compilable to TLA+"
    end

    test "unsupported sub-expression in valid context" do
      ast = quote(do: some_func(x) > 0)
      assert {:partial, "TRUE > 0", [warning]} = GuardCompiler.compile(ast)
      assert warning.message =~ "not compilable to TLA+"
    end

    test "pipe operator returns TRUE with warning" do
      ast = quote(do: x |> String.length())
      assert {:partial, "TRUE", [warning]} = GuardCompiler.compile(ast)
      assert warning.message =~ "not compilable to TLA+"
    end
  end

  describe "real-world guard patterns" do
    test "comparison with bound variable" do
      ast = quote(do: token > tracks.fence_token)
      bindings = %{token: "msg_token"}
      assert {:ok, "msg_token > fence_token"} = GuardCompiler.compile(ast, bindings)
    end

    test "compound boolean with bindings" do
      ast = quote(do: client_id == tracks.holder and token == tracks.fence_token)
      bindings = %{client_id: "msg_client_id", token: "msg_token"}

      assert {:ok, "(msg_client_id = holder /\\ msg_token = fence_token)"} =
               GuardCompiler.compile(ast, bindings)
    end

    test "blackjack guard: bet within balance" do
      ast = quote(do: chips <= tracks.balance)
      bindings = %{chips: "msg_chips"}
      assert {:ok, "msg_chips =< balance"} = GuardCompiler.compile(ast, bindings)
    end

    test "pipeline guard: demand limit" do
      ast = quote(do: tracks.total_demanded + demand <= 1000)
      bindings = %{demand: "msg_demand"}
      assert {:ok, "(total_demanded + msg_demand) =< 1000"} = GuardCompiler.compile(ast, bindings)
    end

    test "invariant: counter non-negative" do
      ast = quote(do: fn tracks -> tracks.counter >= 0 end)
      assert {:ok, "counter >= 0"} = GuardCompiler.compile(ast)
    end

    test "action: monotonic value" do
      ast = quote(do: fn old, new -> new.value >= old.value end)
      # Note: 'old' and 'new' are just variable names, they'll resolve to TLA+ primed vars
      # in the BuildActions pass. Here we just verify the AST compiles.
      assert {:ok, "value >= value"} = GuardCompiler.compile(ast)
    end
  end
end
