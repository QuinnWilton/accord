defmodule Accord.IR.Type do
  @moduledoc """
  Type representation for protocol contracts.

  A tagged union of simple types, compound types, and literal values.
  Used for both message argument validation and reply matching.
  """

  @type t ::
          :string
          | :integer
          | :pos_integer
          | :non_neg_integer
          | :atom
          | :binary
          | :boolean
          | :term
          | :map
          | {:list, t()}
          | {:tuple, [t()]}
          | {:struct, module()}
          | {:literal, term()}
          | {:union, [t()]}
          | {:tagged, atom(), t() | [t()]}

  @doc """
  Parses a type specification from quoted Elixir AST.

  Handles built-in types like `integer()`, compound types like `[integer()]`,
  struct types like `%Card{}`, union types like `atom() | integer()`, and
  literal values like `:ok` or `42`.
  """
  @spec parse(Macro.t()) :: t()
  def parse({:integer, _, args}) when args in [nil, []], do: :integer
  def parse({:pos_integer, _, args}) when args in [nil, []], do: :pos_integer
  def parse({:non_neg_integer, _, args}) when args in [nil, []], do: :non_neg_integer
  def parse({:atom, _, args}) when args in [nil, []], do: :atom
  def parse({:binary, _, args}) when args in [nil, []], do: :binary
  def parse({:boolean, _, args}) when args in [nil, []], do: :boolean
  def parse({:term, _, args}) when args in [nil, []], do: :term
  def parse({:map, _, args}) when args in [nil, []], do: :map

  # String.t()
  def parse({{:., _, [{:__aliases__, _, [:String]}, :t]}, _, []}), do: :string

  # Struct: %ModuleName{}
  def parse({:%, _, [{:__aliases__, _, parts}, {:%{}, _, []}]}) do
    {:struct, Module.concat(parts)}
  end

  # List: [element_type]
  def parse([element_type]) do
    {:list, parse(element_type)}
  end

  # Tuple: {a, b, c, ...}
  def parse({:{}, _, elements}) do
    {:tuple, Enum.map(elements, &parse/1)}
  end

  # Two-element tuple special case (Elixir AST doesn't use :{} for 2-tuples).
  def parse({a, b}) when not is_atom(a) or a not in [:%, :|, :"::", :.] do
    {:tuple, [parse(a), parse(b)]}
  end

  # Union: type_a | type_b
  def parse({:|, _, [left, right]}) do
    left_types = flatten_union(parse(left))
    right_types = flatten_union(parse(right))
    {:union, left_types ++ right_types}
  end

  # Literal atom
  def parse(atom) when is_atom(atom) do
    {:literal, atom}
  end

  # Literal integer
  def parse(int) when is_integer(int) do
    {:literal, int}
  end

  # Variable reference — treat as :term (used in pattern positions).
  def parse({name, _, context}) when is_atom(name) and is_atom(context) do
    :term
  end

  defp flatten_union({:union, types}), do: types
  defp flatten_union(type), do: [type]

  @doc """
  Converts a type to a human-readable string.
  """
  @spec to_string(t()) :: String.t()
  def to_string(:string), do: "String.t()"
  def to_string(:integer), do: "integer()"
  def to_string(:pos_integer), do: "pos_integer()"
  def to_string(:non_neg_integer), do: "non_neg_integer()"
  def to_string(:atom), do: "atom()"
  def to_string(:binary), do: "binary()"
  def to_string(:boolean), do: "boolean()"
  def to_string(:term), do: "term()"
  def to_string(:map), do: "map()"
  def to_string({:list, elem}), do: "[#{__MODULE__.to_string(elem)}]"

  def to_string({:tuple, elems}),
    do: "{#{Enum.map_join(elems, ", ", &__MODULE__.to_string/1)}}"

  def to_string({:struct, mod}), do: "%#{inspect(mod)}{}"
  def to_string({:literal, val}), do: inspect(val)
  def to_string({:union, types}), do: Enum.map_join(types, " | ", &__MODULE__.to_string/1)

  def to_string({:tagged, tag, payload}) when is_list(payload) do
    args = Enum.map_join(payload, ", ", &__MODULE__.to_string/1)
    "{#{inspect(tag)}, #{args}}"
  end

  def to_string({:tagged, tag, payload}) do
    "{#{inspect(tag)}, #{__MODULE__.to_string(payload)}}"
  end
end
