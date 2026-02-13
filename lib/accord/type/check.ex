defmodule Accord.Type.Check do
  @moduledoc """
  Runtime type validation for protocol messages.

  Checks values against `Accord.IR.Type.t()` specifications and returns
  detailed error information when validation fails.
  """

  alias Accord.IR.Type

  @type result :: :ok | {:error, reason :: term()}

  @doc """
  Checks if a value conforms to a type specification.

  Returns `:ok` on match, or `{:error, reason}` with mismatch details.
  """
  @spec check(term(), Type.t()) :: result()
  def check(_value, :term), do: :ok

  def check(value, :string) when is_binary(value), do: :ok
  def check(value, :string), do: mismatch(:string, value)

  def check(value, :integer) when is_integer(value), do: :ok
  def check(value, :integer), do: mismatch(:integer, value)

  def check(value, :pos_integer) when is_integer(value) and value > 0, do: :ok
  def check(value, :pos_integer), do: mismatch(:pos_integer, value)

  def check(value, :non_neg_integer) when is_integer(value) and value >= 0, do: :ok
  def check(value, :non_neg_integer), do: mismatch(:non_neg_integer, value)

  def check(value, :atom) when is_atom(value), do: :ok
  def check(value, :atom), do: mismatch(:atom, value)

  def check(value, :binary) when is_binary(value), do: :ok
  def check(value, :binary), do: mismatch(:binary, value)

  def check(value, :boolean) when is_boolean(value), do: :ok
  def check(value, :boolean), do: mismatch(:boolean, value)

  def check(value, :map) when is_map(value), do: :ok
  def check(value, :map), do: mismatch(:map, value)

  def check(value, {:literal, expected}) when value == expected, do: :ok
  def check(value, {:literal, expected}), do: mismatch({:literal, expected}, value)

  def check(value, {:list, elem_type}) when is_list(value) do
    check_list(value, elem_type, 0)
  end

  def check(value, {:list, _}), do: mismatch(:list, value)

  def check(value, {:tuple, elem_types}) when is_tuple(value) do
    if tuple_size(value) == length(elem_types) do
      check_tuple(Tuple.to_list(value), elem_types, 0)
    else
      {:error, {:tuple_size_mismatch, expected: length(elem_types), got: tuple_size(value)}}
    end
  end

  def check(value, {:tuple, _}), do: mismatch(:tuple, value)

  def check(%{__struct__: module}, {:struct, module}), do: :ok

  def check(%{__struct__: actual}, {:struct, expected}),
    do: mismatch({:struct, expected}, {:struct, actual})

  def check(value, {:struct, module}), do: mismatch({:struct, module}, value)

  def check(value, {:union, types}) do
    if Enum.any?(types, &(check(value, &1) == :ok)) do
      :ok
    else
      {:error, {:no_matching_union_type, expected: types, got: value}}
    end
  end

  def check(value, {:tagged, tag, payload_type})
      when is_tuple(value) and tuple_size(value) >= 1 do
    if elem(value, 0) == tag do
      payload = value |> Tuple.to_list() |> tl()

      case payload_type do
        types when is_list(types) ->
          if length(payload) == length(types) do
            check_tuple(payload, types, 1)
          else
            {:error, {:tuple_size_mismatch, expected: length(types) + 1, got: tuple_size(value)}}
          end

        type ->
          if length(payload) == 1 do
            check(hd(payload), type)
          else
            {:error, {:tuple_size_mismatch, expected: 2, got: tuple_size(value)}}
          end
      end
    else
      mismatch({:tagged, tag, payload_type}, value)
    end
  end

  def check(value, {:tagged, tag, payload_type}),
    do: mismatch({:tagged, tag, payload_type}, value)

  defp check_list([], _elem_type, _index), do: :ok

  defp check_list([head | tail], elem_type, index) do
    case check(head, elem_type) do
      :ok -> check_list(tail, elem_type, index + 1)
      {:error, reason} -> {:error, {:list_element, index: index, reason: reason}}
    end
  end

  defp check_tuple([], [], _index), do: :ok

  defp check_tuple([value | values], [type | types], index) do
    case check(value, type) do
      :ok -> check_tuple(values, types, index + 1)
      {:error, reason} -> {:error, {:tuple_element, index: index, reason: reason}}
    end
  end

  defp mismatch(expected, got) do
    {:error, {:type_mismatch, expected: expected, got: got}}
  end

  @doc """
  Validates a message against a pattern specification.

  A pattern is either an atom (bare message) or a tuple where the first
  element is the tag and the rest are type specs for the arguments.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec check_message(term(), term()) :: result()
  def check_message(message, pattern) when is_atom(pattern) do
    if message == pattern do
      :ok
    else
      {:error, {:pattern_mismatch, expected: pattern, got: message}}
    end
  end

  def check_message(message, pattern) when is_tuple(pattern) and is_tuple(message) do
    pattern_list = Tuple.to_list(pattern)
    message_list = Tuple.to_list(message)

    if length(pattern_list) != length(message_list) do
      {:error, {:arity_mismatch, expected: length(pattern_list), got: length(message_list)}}
    else
      [pattern_tag | pattern_types] = pattern_list
      [message_tag | message_args] = message_list

      if pattern_tag != message_tag do
        {:error, {:tag_mismatch, expected: pattern_tag, got: message_tag}}
      else
        check_arguments(message_args, pattern_types, 0)
      end
    end
  end

  def check_message(message, pattern) do
    {:error, {:pattern_mismatch, expected: pattern, got: message}}
  end

  defp check_arguments([], [], _pos), do: :ok

  defp check_arguments([value | values], [type | types], pos) do
    case check(value, type) do
      :ok -> check_arguments(values, types, pos + 1)
      {:error, _} -> {:error, {:argument, pos, type, value}}
    end
  end

  @doc """
  Checks a reply against a list of `{type_spec, next_state}` pairs.

  Returns `{:ok, next_state}` for the first matching branch, or
  `{:error, reason}` if no branch matches.
  """
  @spec check_reply(term(), [{Type.t(), atom()}]) :: {:ok, atom()} | {:error, term()}
  def check_reply(reply, valid_replies) do
    Enum.find_value(
      valid_replies,
      {:error, {:no_matching_reply, reply: reply, valid: valid_replies}},
      fn {type_spec, next_state} ->
        case check(reply, type_spec) do
          :ok -> {:ok, next_state}
          {:error, _} -> nil
        end
      end
    )
  end
end
