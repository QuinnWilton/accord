defmodule Accord.TLA.GuardCompiler do
  @moduledoc """
  Compiles quoted Elixir guard/update/invariant ASTs to TLA+ expressions.

  Walks the quoted AST from `Macro.escape/1` and emits TLA+ expression
  strings. Supports a subset of Elixir operators and functions that have
  direct TLA+ equivalents. Unsupported forms raise `CompileError`.

  ## Supported forms

  | Elixir | TLA+ |
  |--------|------|
  | `a > b` | `a > b` |
  | `a >= b` | `a >= b` |
  | `a < b` | `a < b` |
  | `a <= b` | `a =< b` |
  | `a == b` | `a = b` |
  | `a != b` | `a /= b` |
  | `a + b` | `a + b` |
  | `a - b` | `a - b` |
  | `a * b` | `a * b` |
  | `a and b` | `a /\\\\ b` |
  | `a or b` | `a \\\\/ b` |
  | `not a` | `~a` |
  | `tracks.field` | `field` |
  | `length(list)` | `Len(list)` |
  | `is_integer(x)` | `x \\\\in Int` |

  ## Bindings

  The `bindings` argument maps Elixir variable names to TLA+ identifiers.
  This is used to resolve pattern-match bindings from message patterns:

      # Elixir guard: fn {:bet, chips}, tracks -> chips <= tracks.balance end
      # bindings: %{chips: "msg_chips"}
      # TLA+ output: "msg_chips =< balance"
  """

  @type warning :: %{message: String.t(), ast: Macro.t()}

  @comparison_ops [:>, :>=, :<, :<=, :==, :!=]
  @arithmetic_ops [:+, :-, :*]

  @doc """
  Compiles a quoted Elixir expression to a TLA+ expression string.

  Returns `{:ok, tla_string}` on success. Raises `CompileError` if any
  sub-expression cannot be compiled to TLA+.
  """
  @spec compile(Macro.t(), map()) :: {:ok, String.t()}
  def compile(ast, bindings \\ %{}) do
    {tla, warnings} = do_compile(ast, bindings, [])

    case warnings do
      [] ->
        {:ok, tla}

      _ ->
        messages =
          warnings
          |> Enum.reverse()
          |> Enum.map_join("\n  ", & &1.message)

        raise CompileError,
          description: "cannot compile to TLA+:\n  #{messages}"
    end
  end

  # -- Literals --

  defp do_compile(n, _bindings, warnings) when is_integer(n) do
    {Integer.to_string(n), warnings}
  end

  defp do_compile(true, _bindings, warnings), do: {"TRUE", warnings}
  defp do_compile(false, _bindings, warnings), do: {"FALSE", warnings}
  defp do_compile(nil, _bindings, warnings), do: {"NULL", warnings}

  defp do_compile(atom, _bindings, warnings) when is_atom(atom) do
    {inspect(atom), warnings}
  end

  defp do_compile(s, _bindings, warnings) when is_binary(s) do
    {~s("#{s}"), warnings}
  end

  # -- Variable reference --
  # Context (third element) is nil for unquoted vars or a module name for quoted vars.

  defp do_compile({var, _meta, context}, bindings, warnings)
       when is_atom(var) and is_atom(context) do
    case Map.get(bindings, var) do
      nil -> {Atom.to_string(var), warnings}
      {:list_length, tla_name} -> {tla_name, warnings}
      tla_name -> {tla_name, warnings}
    end
  end

  # -- Dot access: tracks.field → field --

  defp do_compile({{:., _meta1, [Access, :get]}, _meta2, [_map, key]}, _bindings, warnings) do
    {Atom.to_string(key), warnings}
  end

  defp do_compile({{:., _meta1, [{var, _meta2, _ctx}, field]}, _meta3, []}, bindings, warnings)
       when is_atom(field) do
    field_str = Atom.to_string(field)

    case Map.get(bindings, var) do
      :primed -> {"#{field_str}'", warnings}
      _ -> {field_str, warnings}
    end
  end

  # -- Comparison operators --

  defp do_compile({op, _meta, [left, right]}, bindings, warnings) when op in @comparison_ops do
    {l, warnings} = do_compile(left, bindings, warnings)
    {r, warnings} = do_compile(right, bindings, warnings)

    tla_op =
      case op do
        :> -> ">"
        :>= -> ">="
        :< -> "<"
        :<= -> "=<"
        :== -> "="
        :!= -> "/="
      end

    {"#{l} #{tla_op} #{r}", warnings}
  end

  # -- Arithmetic operators --

  defp do_compile({op, _meta, [left, right]}, bindings, warnings) when op in @arithmetic_ops do
    {l, warnings} = do_compile(left, bindings, warnings)
    {r, warnings} = do_compile(right, bindings, warnings)
    tla_op = Atom.to_string(op)
    {"(#{l} #{tla_op} #{r})", warnings}
  end

  # -- Boolean operators --

  defp do_compile({:and, _meta, [left, right]}, bindings, warnings) do
    {l, warnings} = do_compile(left, bindings, warnings)
    {r, warnings} = do_compile(right, bindings, warnings)
    {"(#{l} /\\ #{r})", warnings}
  end

  defp do_compile({:or, _meta, [left, right]}, bindings, warnings) do
    {l, warnings} = do_compile(left, bindings, warnings)
    {r, warnings} = do_compile(right, bindings, warnings)
    {"(#{l} \\/ #{r})", warnings}
  end

  defp do_compile({:not, _meta, [expr]}, bindings, warnings) do
    {e, warnings} = do_compile(expr, bindings, warnings)
    {"~#{e}", warnings}
  end

  # -- Built-in functions --

  defp do_compile({:length, _meta, [arg]}, bindings, warnings) do
    # When the argument is a list-length-abstracted variable, emit the
    # length variable directly instead of wrapping in Len().
    case arg do
      {var, _, ctx} when is_atom(var) and is_atom(ctx) ->
        case Map.get(bindings, var) do
          {:list_length, tla_name} -> {tla_name, warnings}
          _ -> compile_len(arg, bindings, warnings)
        end

      _ ->
        compile_len(arg, bindings, warnings)
    end
  end

  defp do_compile({:is_integer, _meta, [arg]}, bindings, warnings) do
    {a, warnings} = do_compile(arg, bindings, warnings)
    {"#{a} \\in Int", warnings}
  end

  defp do_compile({:is_boolean, _meta, [arg]}, bindings, warnings) do
    {a, warnings} = do_compile(arg, bindings, warnings)
    {"#{a} \\in BOOLEAN", warnings}
  end

  defp do_compile({:abs, _meta, [arg]}, bindings, warnings) do
    {a, warnings} = do_compile(arg, bindings, warnings)
    # TLA+ doesn't have a built-in abs, but TLC supports JavaModule.
    # Use IF-THEN-ELSE for portability.
    {"IF #{a} >= 0 THEN #{a} ELSE -(#{a})", warnings}
  end

  defp do_compile({:div, _meta, [left, right]}, bindings, warnings) do
    {l, warnings} = do_compile(left, bindings, warnings)
    {r, warnings} = do_compile(right, bindings, warnings)
    {"(#{l} \\div #{r})", warnings}
  end

  defp do_compile({:rem, _meta, [left, right]}, bindings, warnings) do
    {l, warnings} = do_compile(left, bindings, warnings)
    {r, warnings} = do_compile(right, bindings, warnings)
    {"(#{l} % #{r})", warnings}
  end

  # -- fn expressions (extract body) --
  # Guards/invariants stored as `fn args -> body end`. We compile the body.

  defp do_compile({:fn, _meta, [{:->, _meta2, [_args, body]}]}, bindings, warnings) do
    do_compile(body, bindings, warnings)
  end

  # -- Block (compile last expression) --

  defp do_compile({:__block__, _meta, exprs}, bindings, warnings) do
    do_compile(List.last(exprs), bindings, warnings)
  end

  # -- Unsupported form → TRUE with warning --

  defp do_compile(ast, _bindings, warnings) do
    warning = %{
      message: "expression not compilable to TLA+: #{Macro.to_string(ast)}",
      ast: ast
    }

    {"TRUE", [warning | warnings]}
  end

  defp compile_len(arg, bindings, warnings) do
    {a, warnings} = do_compile(arg, bindings, warnings)
    {"Len(#{a})", warnings}
  end
end
