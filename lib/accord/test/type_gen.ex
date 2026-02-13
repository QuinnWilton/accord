defmodule Accord.Test.TypeGen do
  @moduledoc """
  Maps `Accord.IR.Type.t()` variants to PropCheck generators.

  Used by the protocol exerciser to generate well-typed and
  intentionally ill-typed messages from protocol transitions.
  """

  use PropCheck

  alias Accord.IR.Type

  # -- Well-typed generators --

  @doc """
  Returns a PropCheck generator for values matching the given IR type.
  """
  @spec gen(Type.t()) :: :proper_types.type()
  def gen(:string), do: binary()
  def gen(:binary), do: binary()
  def gen(:integer), do: integer()
  def gen(:pos_integer), do: pos_integer()
  def gen(:non_neg_integer), do: non_neg_integer()
  def gen(:atom), do: oneof([:a, :b, :c, :x, :y, :z])
  def gen(:boolean), do: boolean()
  def gen(:map), do: exactly(%{})
  def gen(:term), do: oneof([integer(), oneof([:a, :b, :c]), binary()])

  def gen({:literal, val}), do: exactly(val)

  def gen({:list, elem_type}), do: list(gen(elem_type))

  def gen({:tuple, types}) do
    gens = Enum.map(types, &gen/1)

    let vals <- fixed_list(gens) do
      List.to_tuple(vals)
    end
  end

  def gen({:struct, _module}), do: exactly(%{})

  def gen({:union, types}) do
    oneof(Enum.map(types, &gen/1))
  end

  def gen({:tagged, tag, payload}) when is_list(payload) do
    gens = Enum.map(payload, &gen/1)

    let vals <- fixed_list(gens) do
      List.to_tuple([tag | vals])
    end
  end

  def gen({:tagged, tag, payload}) do
    let val <- gen(payload) do
      {tag, val}
    end
  end

  # -- Ill-typed generators --

  @doc """
  Returns a PropCheck generator for values that violate the given IR type.

  For example, `gen_bad(:pos_integer)` generates zero, negative integers,
  binaries, or booleans — anything that is not a positive integer.
  """
  @spec gen_bad(Type.t()) :: :proper_types.type()
  def gen_bad(:string), do: oneof([integer(), boolean(), oneof([:a, :b])])
  def gen_bad(:binary), do: oneof([integer(), boolean(), oneof([:a, :b])])
  def gen_bad(:integer), do: oneof([binary(), boolean(), oneof([:a, :b])])
  def gen_bad(:pos_integer), do: oneof([integer(-100, 0), binary(), boolean()])
  def gen_bad(:non_neg_integer), do: oneof([integer(-100, -1), binary(), boolean()])
  def gen_bad(:atom), do: oneof([integer(), binary(), boolean()])
  def gen_bad(:boolean), do: oneof([integer(), binary(), oneof([:a, :b])])
  def gen_bad(:map), do: oneof([integer(), binary(), boolean()])
  def gen_bad(:term), do: gen(:term)

  def gen_bad({:literal, val}) when is_atom(val) do
    oneof([integer(), binary(), exactly(:__bad_literal__)])
  end

  def gen_bad({:literal, val}) when is_integer(val) do
    oneof([binary(), boolean(), exactly(val + 1)])
  end

  def gen_bad({:literal, _val}), do: oneof([integer(), binary()])

  def gen_bad({:list, _elem}), do: oneof([integer(), binary(), boolean()])
  def gen_bad({:tuple, _types}), do: oneof([integer(), binary(), boolean()])
  def gen_bad({:struct, _mod}), do: oneof([integer(), binary(), boolean()])

  def gen_bad({:union, types}) do
    base = [exactly(:__bad_union__), integer(-100, -1)]
    has_binary = Enum.any?(types, &(&1 in [:binary, :string]))
    if has_binary, do: oneof(base), else: oneof([binary() | base])
  end

  def gen_bad({:tagged, tag, _payload}) do
    oneof([
      exactly({:__wrong_tag__, 0}),
      exactly(tag),
      integer()
    ])
  end

  # -- Message generators --

  @doc """
  Generates a complete well-typed message from a transition.

  For atom messages (no args), returns exactly that atom.
  For tuple messages, generates each argument according to its type.
  """
  @spec gen_message(Accord.IR.Transition.t()) :: :proper_types.type()
  def gen_message(%{message_pattern: pattern, message_types: types}) when is_atom(pattern) do
    if types == [] do
      exactly(pattern)
    else
      exactly(pattern)
    end
  end

  def gen_message(%{message_pattern: pattern, message_types: types}) when is_tuple(pattern) do
    tag = elem(pattern, 0)

    if types == [] do
      exactly(tag)
    else
      gens = Enum.map(types, &gen/1)

      let vals <- fixed_list(gens) do
        List.to_tuple([tag | vals])
      end
    end
  end

  @doc """
  Generates a message with the correct tag but at least one argument
  of the wrong type.

  Returns `nil` for transitions with no typed arguments (atom messages
  or tuples with no type constraints).
  """
  @spec gen_bad_message(Accord.IR.Transition.t()) :: :proper_types.type() | nil
  def gen_bad_message(%{message_pattern: pattern, message_types: types})
      when is_atom(pattern) or types == [] do
    nil
  end

  def gen_bad_message(%{message_pattern: pattern, message_types: types}) when is_tuple(pattern) do
    tag = elem(pattern, 0)

    let bad_pos <- integer(0, length(types) - 1) do
      args =
        types
        |> Enum.with_index()
        |> Enum.map(fn {type, idx} ->
          if idx == bad_pos do
            {:ok, val} = :proper_gen.pick(gen_bad(type))
            val
          else
            {:ok, val} = :proper_gen.pick(gen(type))
            val
          end
        end)

      List.to_tuple([tag | args])
    end
  end
end
