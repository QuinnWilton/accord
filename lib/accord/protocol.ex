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
        only: [
          initial: 1,
          role: 1,
          track: 3,
          state: 2,
          state: 3,
          anystate: 1,
          on: 2,
          cast: 1
        ]

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
  Declares a participant role.
  """
  defmacro role(name) do
    span = span_ast(__CALLER__)

    quote do
      Module.put_attribute(
        __MODULE__,
        :accord_roles,
        %Accord.IR.Role{name: unquote(name), span: unquote(span)}
      )
    end
  end

  @doc """
  Declares a tracked accumulator.

      track :counter, :non_neg_integer, default: 0
      track :holder, :term, default: nil
  """
  defmacro track(name, type, opts) do
    default = Keyword.fetch!(opts, :default)
    type_value = parse_track_type(type)
    escaped_type = Macro.escape(type_value)
    span = span_ast(__CALLER__)

    quote do
      Module.put_attribute(
        __MODULE__,
        :accord_tracks,
        %Accord.IR.Track{
          name: unquote(name),
          type: unquote(escaped_type),
          default: unquote(default),
          span: unquote(span)
        }
      )
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
  Defines a transition.

  ## Keyword form

      on :ping, reply: :pong
      on :stop, reply: :stopped, goto: :stopped
      on {:get, key :: atom()}, reply: term(), goto: :ready

  ## Block form

      on {:acquire, client_id :: term(), token :: pos_integer()} do
        reply {:ok, pos_integer()}
        goto :locked
        guard fn {:acquire, _client_id, token}, tracks ->
          token > tracks.fence_token
        end
        update fn {:acquire, client_id, token}, _reply, tracks ->
          %{tracks | holder: client_id, fence_token: token}
        end
      end

  ## Branching form

      on {:bet, chips :: pos_integer()} do
        guard fn {:bet, chips}, tracks -> chips <= tracks.balance end
        branch {:ok, %Bet{}} -> :dealt
        branch {:error, :insufficient_funds} -> :waiting
      end
  """
  defmacro on(message_spec, do: block) do
    {message_pattern, message_types} = parse_message_spec(message_spec)
    escaped_types = Macro.escape(message_types)
    span = span_ast(__CALLER__)

    quote do
      import Accord.Protocol.Block

      Module.put_attribute(__MODULE__, :accord_on_reply_type, nil)
      Module.put_attribute(__MODULE__, :accord_on_goto, nil)
      Module.put_attribute(__MODULE__, :accord_on_guard, nil)
      Module.put_attribute(__MODULE__, :accord_on_update, nil)
      Module.put_attribute(__MODULE__, :accord_on_branches, [])

      unquote(block)

      reply_type = Module.get_attribute(__MODULE__, :accord_on_reply_type)
      goto_state = Module.get_attribute(__MODULE__, :accord_on_goto)
      guard_pair = Module.get_attribute(__MODULE__, :accord_on_guard)
      update_pair = Module.get_attribute(__MODULE__, :accord_on_update)
      explicit_branches = Module.get_attribute(__MODULE__, :accord_on_branches) |> Enum.reverse()

      in_anystate = Module.get_attribute(__MODULE__, :accord_in_anystate, false)

      # Build branches: explicit branches take precedence, else build from reply/goto.
      branches =
        if explicit_branches != [] do
          explicit_branches
        else
          next = if in_anystate, do: :__same__, else: goto_state

          if reply_type do
            [%Branch{reply_type: reply_type, next_state: next || :__same__, span: unquote(span)}]
          else
            []
          end
        end

      transition = %Transition{
        message_pattern: unquote(message_pattern),
        message_types: unquote(escaped_types),
        kind: :call,
        branches: branches,
        guard: guard_pair,
        update: update_pair,
        span: unquote(span)
      }

      if in_anystate do
        Module.put_attribute(__MODULE__, :accord_anystate, transition)
      else
        current = Module.get_attribute(__MODULE__, :accord_current_transitions)
        Module.put_attribute(__MODULE__, :accord_current_transitions, [transition | current])
      end

      Module.delete_attribute(__MODULE__, :accord_on_reply_type)
      Module.delete_attribute(__MODULE__, :accord_on_goto)
      Module.delete_attribute(__MODULE__, :accord_on_guard)
      Module.delete_attribute(__MODULE__, :accord_on_update)
      Module.delete_attribute(__MODULE__, :accord_on_branches)

      import Accord.Protocol.Block, only: []
    end
  end

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
    roles_raw = Module.get_attribute(env.module, :accord_roles) |> Enum.reverse()
    tracks_raw = Module.get_attribute(env.module, :accord_tracks) |> Enum.reverse()
    properties_raw = Module.get_attribute(env.module, :accord_properties) |> Enum.reverse()

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
      roles: roles_raw,
      tracks: tracks_raw,
      states: states,
      anystate: anystate_raw,
      properties: properties_raw
    }

    # Run validation pipeline.
    ir =
      case compile_ir(ir, env) do
        {:ok, validated_ir} -> validated_ir
        # compile_ir raises on error, so this is defensive.
        {:error, _} -> ir
      end

    # Build runtime artifacts.
    {:ok, table} = Accord.Pass.BuildTransitionTable.run(ir)
    {:ok, track_init} = Accord.Pass.BuildTrackInit.run(ir)

    compiled = %Accord.Monitor.Compiled{
      ir: ir,
      transition_table: table,
      track_init: track_init
    }

    # Store IR and compiled data in module attributes. We use
    # persistent_term to make them accessible from def bodies, since
    # Macro.escape can't handle closures in guard/update functions.
    Module.put_attribute(env.module, :accord_ir, ir)
    Module.put_attribute(env.module, :accord_compiled, compiled)

    monitor_module = Module.concat(env.module, Monitor)
    pt_key = {Accord.Protocol, env.module}

    quote do
      # Module body: evaluated at compile time. @accord_ir/@accord_compiled
      # read the attribute values (including closures) as-is, then stash
      # them in persistent_term for runtime access from def bodies.
      :persistent_term.put({unquote(pt_key), :ir}, @accord_ir)
      :persistent_term.put({unquote(pt_key), :compiled}, @accord_compiled)

      def __ir__, do: :persistent_term.get({unquote(pt_key), :ir})
      def __compiled__, do: :persistent_term.get({unquote(pt_key), :compiled})

      defmodule unquote(monitor_module) do
        @moduledoc """
        Runtime monitor for `#{inspect(unquote(env.module))}`.

        Thin wrapper around `Accord.Monitor` with compiled protocol data baked in.
        """

        def start_link(opts) do
          compiled = :persistent_term.get({unquote(pt_key), :compiled})
          Accord.Monitor.start_link(compiled, opts)
        end

        def child_spec(opts) do
          %{
            id: __MODULE__,
            start: {__MODULE__, :start_link, [opts]}
          }
        end
      end
    end
  end

  defp compile_ir(ir, env) do
    alias Accord.Pass

    with {:ok, ir} <- Pass.RefineSpans.run(ir),
         {:ok, ir} <- run_pass(Pass.ValidateStructure, ir, env),
         {:ok, ir} <- run_pass(Pass.ValidateTypes, ir, env),
         {:ok, ir} <- run_pass(Pass.ValidateDeterminism, ir, env) do
      {:ok, ir}
    end
  end

  defp run_pass(pass_module, ir, env) do
    case pass_module.run(ir) do
      {:ok, ir} ->
        {:ok, ir}

      {:error, reports} ->
        message =
          reports
          |> Enum.map(fn report ->
            source =
              if ir.source_file && File.exists?(ir.source_file) do
                Pentiment.Source.from_file(ir.source_file)
              else
                nil
              end

            Pentiment.format(report, source)
          end)
          |> Enum.join("\n\n")

        raise CompileError,
          description: message,
          file: env.file,
          line: env.line
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

  # -- Track Type Parsing --

  defp parse_track_type(:string), do: :string
  defp parse_track_type(:integer), do: :integer
  defp parse_track_type(:pos_integer), do: :pos_integer
  defp parse_track_type(:non_neg_integer), do: :non_neg_integer
  defp parse_track_type(:atom), do: :atom
  defp parse_track_type(:binary), do: :binary
  defp parse_track_type(:boolean), do: :boolean
  defp parse_track_type(:term), do: :term
  defp parse_track_type(:map), do: :map

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
