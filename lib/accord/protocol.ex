defmodule Accord.Protocol do
  @moduledoc """
  DSL for defining protocol state machines.

  Protocols define the valid sequence of messages between participants,
  expected reply types, and state transitions.

  ## Example

      defmodule Counter.Protocol do
        use Accord.Protocol

        initial :ready

        state :ready do
          on {:increment, amount :: pos_integer()}, reply: {:ok, integer()}, goto: :ready
          on :get, reply: {:value, integer()}, goto: :ready
          on :stop, reply: :stopped, goto: :stopped
        end

        state :stopped, terminal: true

        anystate do
          on :ping, reply: :pong
          cast :heartbeat
        end
      end

  ## Keyword form

  The keyword form is compact for simple transitions:

      on :ping, reply: :pong
      on :stop, reply: :stopped, goto: :stopped
      on {:get, key :: atom()}, reply: term(), goto: :ready

  ## Anystate

  Commands in the `anystate` block are valid in any non-terminal state.
  They cannot specify `goto:` — they stay in the current state.

  ## Casts

  Casts are async fire-and-forget messages with no reply:

      cast :heartbeat
  """

  alias Accord.IR
  alias Accord.IR.{Branch, State, Transition}

  defmacro __using__(opts) do
    quote do
      import Accord.Protocol,
        only: [initial: 1, state: 2, state: 3, anystate: 1, on: 2, cast: 1]

      Module.register_attribute(__MODULE__, :accord_initial, [])
      Module.register_attribute(__MODULE__, :accord_states, accumulate: true)
      Module.register_attribute(__MODULE__, :accord_anystate, accumulate: true)
      Module.register_attribute(__MODULE__, :accord_roles, accumulate: true)
      Module.register_attribute(__MODULE__, :accord_tracks, accumulate: true)
      Module.register_attribute(__MODULE__, :accord_properties, accumulate: true)
      Module.put_attribute(__MODULE__, :accord_opts, unquote(Macro.escape(opts)))

      @before_compile Accord.Protocol
    end
  end

  # -- DSL Macros --

  @doc """
  Declares the initial state of the protocol. Required.
  """
  defmacro initial(state_name) do
    quote do
      Module.put_attribute(__MODULE__, :accord_initial, unquote(state_name))
    end
  end

  @doc """
  Defines a state with transitions.

      state :ready do
        on :ping, reply: :pong, goto: :ready
      end

  Or a terminal state with no transitions:

      state :stopped, terminal: true
  """
  defmacro state(name, opts_or_block)

  defmacro state(name, do: block) do
    span = span_ast(__CALLER__)

    quote do
      Module.put_attribute(__MODULE__, :accord_current_state, unquote(name))
      Module.put_attribute(__MODULE__, :accord_current_transitions, [])

      unquote(block)

      transitions =
        Module.get_attribute(__MODULE__, :accord_current_transitions) |> Enum.reverse()

      Module.put_attribute(
        __MODULE__,
        :accord_states,
        {unquote(name), false, transitions, unquote(span)}
      )

      Module.delete_attribute(__MODULE__, :accord_current_state)
      Module.delete_attribute(__MODULE__, :accord_current_transitions)
    end
  end

  defmacro state(name, opts) when is_list(opts) do
    terminal = Keyword.get(opts, :terminal, false)
    span = span_ast(__CALLER__)

    quote do
      Module.put_attribute(
        __MODULE__,
        :accord_states,
        {unquote(name), unquote(terminal), [], unquote(span)}
      )
    end
  end

  @doc """
  Defines a state with options and a transitions block.
  """
  defmacro state(name, opts, do: block) when is_list(opts) do
    terminal = Keyword.get(opts, :terminal, false)
    span = span_ast(__CALLER__)

    quote do
      Module.put_attribute(__MODULE__, :accord_current_state, unquote(name))
      Module.put_attribute(__MODULE__, :accord_current_transitions, [])

      unquote(block)

      transitions =
        Module.get_attribute(__MODULE__, :accord_current_transitions) |> Enum.reverse()

      Module.put_attribute(
        __MODULE__,
        :accord_states,
        {unquote(name), unquote(terminal), transitions, unquote(span)}
      )

      Module.delete_attribute(__MODULE__, :accord_current_state)
      Module.delete_attribute(__MODULE__, :accord_current_transitions)
    end
  end

  @doc """
  Defines anystate transitions valid in all non-terminal states.
  """
  defmacro anystate(do: block) do
    quote do
      Module.put_attribute(__MODULE__, :accord_in_anystate, true)
      unquote(block)
      Module.delete_attribute(__MODULE__, :accord_in_anystate)
    end
  end

  @doc """
  Defines a transition in keyword form.

      on :ping, reply: :pong
      on :stop, reply: :stopped, goto: :stopped
      on {:get, key :: atom()}, reply: term(), goto: :ready
  """
  defmacro on(message_spec, opts) when is_list(opts) do
    reply_spec = Keyword.fetch!(opts, :reply)
    next_state = Keyword.get(opts, :goto)

    {message_pattern, message_types} = parse_message_spec(message_spec)
    reply_type = parse_reply_spec(reply_spec)

    escaped_types = Macro.escape(message_types)
    escaped_reply_type = Macro.escape(reply_type)

    span = span_ast(__CALLER__)
    caller_file = __CALLER__.file
    caller_line = __CALLER__.line

    quote do
      in_anystate = Module.get_attribute(__MODULE__, :accord_in_anystate, false)

      if in_anystate do
        if unquote(next_state) do
          raise CompileError,
            description: "anystate transitions cannot specify goto:",
            file: unquote(caller_file),
            line: unquote(caller_line)
        end

        transition = %Transition{
          message_pattern: unquote(message_pattern),
          message_types: unquote(escaped_types),
          kind: :call,
          branches: [
            %Branch{
              reply_type: unquote(escaped_reply_type),
              next_state: :__same__,
              span: unquote(span)
            }
          ],
          span: unquote(span)
        }

        Module.put_attribute(__MODULE__, :accord_anystate, transition)
      else
        unless unquote(next_state) do
          raise CompileError,
            description: "state transitions must specify goto:",
            file: unquote(caller_file),
            line: unquote(caller_line)
        end

        transition = %Transition{
          message_pattern: unquote(message_pattern),
          message_types: unquote(escaped_types),
          kind: :call,
          branches: [
            %Branch{
              reply_type: unquote(escaped_reply_type),
              next_state: unquote(next_state),
              span: unquote(span)
            }
          ],
          span: unquote(span)
        }

        current = Module.get_attribute(__MODULE__, :accord_current_transitions)
        Module.put_attribute(__MODULE__, :accord_current_transitions, [transition | current])
      end
    end
  end

  @doc """
  Defines a cast (async fire-and-forget, no reply).
  """
  defmacro cast(message_spec) do
    {message_pattern, message_types} = parse_message_spec(message_spec)
    escaped_types = Macro.escape(message_types)
    span = span_ast(__CALLER__)

    quote do
      in_anystate = Module.get_attribute(__MODULE__, :accord_in_anystate, false)

      transition = %Transition{
        message_pattern: unquote(message_pattern),
        message_types: unquote(escaped_types),
        kind: :cast,
        branches: [],
        span: unquote(span)
      }

      if in_anystate do
        Module.put_attribute(__MODULE__, :accord_anystate, transition)
      else
        current = Module.get_attribute(__MODULE__, :accord_current_transitions)
        Module.put_attribute(__MODULE__, :accord_current_transitions, [transition | current])
      end
    end
  end

  # -- @before_compile --

  defmacro __before_compile__(env) do
    initial = Module.get_attribute(env.module, :accord_initial)
    states_raw = Module.get_attribute(env.module, :accord_states) |> Enum.reverse()
    anystate_raw = Module.get_attribute(env.module, :accord_anystate) |> Enum.reverse()

    if is_nil(initial) do
      raise CompileError,
        description: "protocol #{inspect(env.module)} must declare `initial :state`",
        file: env.file,
        line: env.line
    end

    states =
      for {name, terminal, transitions, span} <- states_raw, into: %{} do
        {name, %State{name: name, terminal: terminal, transitions: transitions, span: span}}
      end

    ir = %IR{
      name: env.module,
      source_file: env.file,
      initial: initial,
      states: states,
      anystate: anystate_raw
    }

    escaped_ir = Macro.escape(ir)

    quote do
      def __ir__, do: unquote(escaped_ir)
    end
  end

  # -- Message Spec Parsing --

  @doc false
  def parse_message_spec(spec) when is_atom(spec), do: {spec, []}

  # Variable reference (bare atom at macro time).
  def parse_message_spec({tag, _, nil}) when is_atom(tag), do: {tag, []}

  # Tuple with 3+ elements: {:{}, _, elements}
  def parse_message_spec({:{}, _, elements}), do: parse_tuple_message(elements)

  # Two-element tuple: {tag, arg}
  def parse_message_spec({tag, arg}) when is_atom(tag), do: parse_tuple_message([tag, arg])

  # Two-element tuple where tag is a variable ref.
  def parse_message_spec({{tag, _, nil}, arg}) when is_atom(tag),
    do: parse_tuple_message([tag, arg])

  defp parse_tuple_message([tag | rest]) do
    tag_value =
      case tag do
        {name, _, nil} when is_atom(name) -> name
        name when is_atom(name) -> name
      end

    types =
      Enum.map(rest, fn
        {:"::", _, [_name, type_ast]} -> IR.Type.parse(type_ast)
        type_ast -> IR.Type.parse(type_ast)
      end)

    pattern =
      case length(types) do
        0 -> tag_value
        1 -> {tag_value, :_}
        _ -> {:{}, [], [tag_value | List.duplicate(:_, length(types))]}
      end

    {pattern, types}
  end

  @doc false
  def parse_reply_spec(spec) when is_atom(spec), do: {:literal, spec}

  def parse_reply_spec({:|, _, _} = union), do: parse_reply_union(union)

  def parse_reply_spec({:{}, _, elements}), do: parse_reply_tuple(elements)

  # Two-element tuple like {:ok, integer()}.
  def parse_reply_spec({tag, payload}) when is_atom(tag), do: parse_reply_tuple([tag, payload])

  def parse_reply_spec(other), do: IR.Type.parse(other)

  defp parse_reply_union({:|, _, [left, right]}) do
    left_types = flatten_reply_union(parse_reply_spec(left))
    right_types = flatten_reply_union(parse_reply_spec(right))
    {:union, left_types ++ right_types}
  end

  defp flatten_reply_union({:union, types}), do: types
  defp flatten_reply_union(type), do: [type]

  defp parse_reply_tuple([tag | rest]) do
    tag_value =
      case tag do
        {name, _, nil} when is_atom(name) -> name
        name when is_atom(name) -> name
      end

    types =
      Enum.map(rest, fn
        {:"::", _, [_name, type_ast]} -> IR.Type.parse(type_ast)
        type_ast -> IR.Type.parse(type_ast)
      end)

    case types do
      [] -> {:literal, tag_value}
      [single] -> {:tagged, tag_value, single}
      multiple -> {:tagged, tag_value, multiple}
    end
  end

  # -- Span Helpers --

  defp span_ast(caller) do
    meta = [line: caller.line]

    meta =
      case Map.get(caller, :column) do
        nil -> meta
        col -> Keyword.put(meta, :column, col)
      end

    quote do
      Pentiment.Elixir.span_from_meta(unquote(meta))
    end
  end
end
