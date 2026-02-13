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
  alias Accord.TLA.{ModelConfig, SpanMap}

  @doc """
  State predicate for use in liveness properties.

      liveness in_state(:locked), leads_to: in_state(:unlocked)
  """
  @spec in_state(atom()) :: {:in_state, atom()}
  def in_state(name), do: {:in_state, name}

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
          cast: 1,
          property: 2,
          in_state: 1
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
    span = span_from_name_ast(name, __CALLER__)

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

      on {:acquire, client_id :: term()} do
        reply {:ok, pos_integer()}
        goto :locked
        update fn {:acquire, cid}, {:ok, token}, tracks ->
          %{tracks | holder: cid, fence_token: token}
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
    {message_pattern, message_types, message_arg_names, message_arg_spans} =
      parse_message_spec(message_spec)

    escaped_types = Macro.escape(message_types)
    escaped_arg_names = Macro.escape(message_arg_names)
    escaped_arg_spans = Macro.escape(message_arg_spans)
    span = message_span_ast(message_spec, __CALLER__)

    quote do
      import Accord.Protocol.Block

      Module.put_attribute(__MODULE__, :accord_on_reply_type, nil)
      Module.put_attribute(__MODULE__, :accord_on_reply_constraint, nil)
      Module.put_attribute(__MODULE__, :accord_on_reply_span, nil)
      Module.put_attribute(__MODULE__, :accord_on_goto, nil)
      Module.put_attribute(__MODULE__, :accord_on_goto_span, nil)
      Module.put_attribute(__MODULE__, :accord_on_guard, nil)
      Module.put_attribute(__MODULE__, :accord_on_update, nil)
      Module.put_attribute(__MODULE__, :accord_on_branches, [])

      unquote(block)

      reply_type = Module.get_attribute(__MODULE__, :accord_on_reply_type)
      reply_constraint = Module.get_attribute(__MODULE__, :accord_on_reply_constraint)
      reply_span = Module.get_attribute(__MODULE__, :accord_on_reply_span)
      goto_state = Module.get_attribute(__MODULE__, :accord_on_goto)
      goto_span = Module.get_attribute(__MODULE__, :accord_on_goto_span)
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
            [
              %Branch{
                reply_type: reply_type,
                next_state: next || :__same__,
                constraint: reply_constraint,
                span: reply_span || unquote(span),
                next_state_span: goto_span
              }
            ]
          else
            []
          end
        end

      transition = %Transition{
        message_pattern: unquote(message_pattern),
        message_types: unquote(escaped_types),
        message_arg_names: unquote(escaped_arg_names),
        message_arg_spans: unquote(escaped_arg_spans),
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
      Module.delete_attribute(__MODULE__, :accord_on_reply_constraint)
      Module.delete_attribute(__MODULE__, :accord_on_reply_span)
      Module.delete_attribute(__MODULE__, :accord_on_goto)
      Module.delete_attribute(__MODULE__, :accord_on_goto_span)
      Module.delete_attribute(__MODULE__, :accord_on_guard)
      Module.delete_attribute(__MODULE__, :accord_on_update)
      Module.delete_attribute(__MODULE__, :accord_on_branches)

      import Accord.Protocol.Block, only: []
    end
  end

  defmacro on(message_spec, opts) when is_list(opts) do
    reply_spec = Keyword.fetch!(opts, :reply)
    next_state = Keyword.get(opts, :goto)

    {message_pattern, message_types, message_arg_names, message_arg_spans} =
      parse_message_spec(message_spec)

    reply_type = parse_reply_spec(reply_spec)

    escaped_types = Macro.escape(message_types)
    escaped_arg_names = Macro.escape(message_arg_names)
    escaped_arg_spans = Macro.escape(message_arg_spans)
    escaped_reply_type = Macro.escape(reply_type)

    span = message_span_ast(message_spec, __CALLER__)
    reply_pattern = Macro.to_string(reply_spec)
    next_state_pattern = if next_state, do: inspect(next_state)
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
          message_arg_names: unquote(escaped_arg_names),
          message_arg_spans: unquote(escaped_arg_spans),
          kind: :call,
          branches: [
            %Branch{
              reply_type: unquote(escaped_reply_type),
              next_state: :__same__,
              span:
                Pentiment.Span.search(
                  line: unquote(caller_line),
                  pattern: unquote(reply_pattern)
                )
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

        next_state_span =
          if unquote(next_state_pattern) do
            Pentiment.Span.search(
              line: unquote(caller_line),
              pattern: unquote(next_state_pattern)
            )
          end

        transition = %Transition{
          message_pattern: unquote(message_pattern),
          message_types: unquote(escaped_types),
          message_arg_names: unquote(escaped_arg_names),
          message_arg_spans: unquote(escaped_arg_spans),
          kind: :call,
          branches: [
            %Branch{
              reply_type: unquote(escaped_reply_type),
              next_state: unquote(next_state),
              next_state_span: next_state_span,
              span:
                Pentiment.Span.search(
                  line: unquote(caller_line),
                  pattern: unquote(reply_pattern)
                )
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
    {message_pattern, message_types, _message_arg_names, _message_arg_spans} =
      parse_message_spec(message_spec)

    escaped_types = Macro.escape(message_types)
    span = message_span_ast(message_spec, __CALLER__)

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

  @doc """
  Defines a named property with one or more checks.

      property :monotonic_tokens do
        action fn old, new -> new.fence_token >= old.fence_token end
      end

      property :holder_set do
        invariant :locked, fn {:acquire, _}, tracks ->
          tracks.holder != nil
        end
      end

      property :token_non_negative do
        invariant fn tracks -> tracks.fence_token >= 0 end
      end

      property :no_starvation do
        liveness in_state(:locked), leads_to: in_state(:unlocked)
      end

  Available check kinds inside property blocks:

  - `invariant fn tracks -> bool end` — global invariant.
  - `invariant :state, fn msg, tracks -> bool end` — local invariant.
  - `action fn old_tracks, new_tracks -> bool end` — action property.
  - `liveness trigger, leads_to: target` — liveness with optional `fairness:`.
  - `correspondence :open, [:close]` — open/close pairing.
  - `bounded :track, max: N` — bounded track value.
  - `ordered :event, by: :field` — event ordering.
  - `precedence :target, :required` — state precedence.
  - `reachable :target` — design-time reachability check.
  - `forbidden fn state, tracks -> bool end` — negated invariant.
  """
  defmacro property(name, do: block) do
    span = span_from_name_ast(name, __CALLER__)

    quote do
      import Accord.Protocol.Property

      Module.put_attribute(__MODULE__, :accord_property_checks, [])

      unquote(block)

      checks =
        Module.get_attribute(__MODULE__, :accord_property_checks) |> Enum.reverse()

      Module.put_attribute(
        __MODULE__,
        :accord_properties,
        %Accord.IR.Property{
          name: unquote(name),
          checks: checks,
          span: unquote(span)
        }
      )

      Module.delete_attribute(__MODULE__, :accord_property_checks)

      import Accord.Protocol.Property, only: []
    end
  end

  # -- @before_compile --

  defmacro __before_compile__(env) do
    {ir, fn_specs, tla_result} = compile_protocol(env)

    ir_bin = :erlang.term_to_binary(ir)
    compiled_bin = :erlang.term_to_binary(build_compiled(ir))
    Module.put_attribute(env.module, :accord_ir_bin, ir_bin)
    Module.put_attribute(env.module, :accord_compiled_bin, compiled_bin)

    fn_defs = fn_to_defs(fn_specs)
    span_defs = build_span_defs(tla_result)
    domains_map = build_domains_map(tla_result)
    monitor_module = Module.concat(env.module, Monitor)
    parent_module = env.module

    quote do
      unquote_splicing(fn_defs)

      # :safe mode cannot be used here because the IR contains lifted
      # function references (EXPORT_EXT) that require atom creation.
      # These binaries are generated at compile time, never from untrusted sources.
      def __ir__, do: :erlang.binary_to_term(@accord_ir_bin)
      def __compiled__, do: :erlang.binary_to_term(@accord_compiled_bin)
      def __tla_domains__, do: unquote(Macro.escape(domains_map))

      @doc false
      unquote_splicing(span_defs)
      def __tla_span__(_), do: nil

      defmodule unquote(monitor_module) do
        @moduledoc """
        Runtime monitor for `#{inspect(unquote(parent_module))}`.

        Thin wrapper around `Accord.Monitor` with compiled protocol data baked in.
        """

        def start_link(opts) do
          compiled = unquote(parent_module).__compiled__()
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

  defp compile_protocol(env) do
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

    # Emit reachability warnings through the compiler.
    for report <- Accord.Pass.ValidateReachability.warnings(ir) do
      IO.warn(report.message, Macro.Env.stacktrace(env))
    end

    # Lift anonymous closures into named module functions so they
    # serialize as EXPORT_EXT (MFA references) rather than NEW_FUN_EXT
    # (which encodes references to the temporary compiler module that
    # won't exist when the .beam is loaded in a later VM session).
    {ir, fn_specs} = lift_closures(ir, env.module)

    # Compile upward → TLA+ spec.
    opts = Module.get_attribute(env.module, :accord_opts) || []
    tla_result = compile_tla(ir, opts, env)

    {ir, fn_specs, tla_result}
  end

  defp build_compiled(ir) do
    {:ok, table} = Accord.Pass.BuildTransitionTable.run(ir)
    {:ok, track_init} = Accord.Pass.BuildTrackInit.run(ir)

    %Accord.Monitor.Compiled{
      ir: ir,
      transition_table: table,
      track_init: track_init
    }
  end

  defp build_span_defs(tla_result) do
    case tla_result do
      {:ok, %{span_map: span_map}} ->
        for {name, span} <- span_map do
          escaped_span = Macro.escape(span)

          quote do
            def __tla_span__(unquote(name)), do: unquote(escaped_span)
          end
        end

      _ ->
        []
    end
  end

  # Build a map of variable name → TLA+ domain string for overflow detection.
  defp build_domains_map({:ok, %{state_space: ss}}) do
    Map.new(ss.variables, fn var -> {var.name, var.type} end)
  end

  defp build_domains_map(_), do: %{}

  defp compile_ir(ir, env) do
    alias Accord.Pass

    with {:ok, ir} <- Pass.RefineSpans.run(ir),
         {:ok, ir} <- run_pass(Pass.ValidateStructure, ir, env),
         {:ok, ir} <- run_pass(Pass.ValidateTypes, ir, env),
         {:ok, ir} <- run_pass(Pass.ValidateDeterminism, ir, env),
         {:ok, ir} <- run_pass(Pass.ValidateReachability, ir, env),
         {:ok, ir} <- run_pass(Pass.ValidateProperties, ir, env),
         {:ok, ir} <- run_pass(Pass.ResolveFieldPaths, ir, env) do
      {:ok, ir}
    end
  end

  defp run_pass(pass_module, ir, env) do
    case pass_module.run(ir) do
      {:ok, ir} ->
        {:ok, ir}

      {:error, reports} ->
        source =
          if ir.source_file && File.exists?(ir.source_file) do
            Pentiment.Source.from_file(ir.source_file)
          else
            nil
          end

        message =
          reports
          |> Enum.map(fn report -> Pentiment.format(report, source) end)
          |> Enum.join("\n\n")

        raise CompileError,
          description: message,
          file: env.file,
          line: env.line
    end
  end

  # -- TLA+ Compilation --

  defp compile_tla(ir, opts, env) do
    model_path = Keyword.get(opts, :model)
    project_root = Mix.Project.build_path() |> Path.join("../../") |> Path.expand()

    config =
      ModelConfig.load(
        protocol_config_path: model_path,
        project_root: project_root
      )

    case Accord.TLA.Compiler.compile(ir, config) do
      {:ok, result} ->
        # Write .tla and .cfg to _build/accord/.
        write_tla_files(ir.name, result, env)

        # Build span map for __tla_span__/1.
        span_map = SpanMap.build(ir, result.actions)
        {:ok, Map.put(result, :span_map, span_map)}

      {:error, reason} ->
        IO.warn(
          "TLA+ compilation failed for #{inspect(ir.name)}: #{inspect(reason)}",
          Macro.Env.stacktrace(env)
        )

        :error
    end
  rescue
    e ->
      IO.warn(
        "TLA+ compilation failed for #{inspect(ir.name)}: #{Exception.message(e)}",
        Macro.Env.stacktrace(env)
      )

      :error
  end

  defp write_tla_files(module_name, result, _env) do
    # Derive path from module name: Lock.Protocol → lock/Protocol.
    # The file base name must match the TLA+ MODULE name (PascalCase).
    parts = Module.split(module_name)
    dir_parts = parts |> Enum.slice(0..-2//1) |> Enum.map(&Macro.underscore/1)

    base_dir = Path.join([Mix.Project.build_path(), "accord" | dir_parts])
    base_name = List.last(parts)

    File.mkdir_p!(base_dir)
    File.write!(Path.join(base_dir, "#{base_name}.tla"), result.tla)
    File.write!(Path.join(base_dir, "#{base_name}.cfg"), result.cfg)
  end

  # -- Closure Lifting --
  #
  # Anonymous closures defined in guard/update/invariant/action/forbidden
  # macros reference the temporary :elixir_compiler_N module that exists
  # only during compilation. When serialized via term_to_binary and
  # deserialized in a later VM session, those references break.
  #
  # lift_closures/2 replaces each closure with an external function
  # capture (&Module.__accord_fn_N__/arity) and collects the fn ASTs
  # so they can be compiled as named functions in the module.

  defp lift_closures(ir, module) do
    acc = {0, []}

    {states, acc} =
      Enum.reduce(ir.states, {%{}, acc}, fn {name, state}, {states, acc} ->
        {transitions, acc} = lift_transition_list(state.transitions, module, acc)
        {Map.put(states, name, %{state | transitions: transitions}), acc}
      end)

    {anystate, acc} = lift_transition_list(ir.anystate, module, acc)
    {properties, acc} = lift_property_list(ir.properties, module, acc)

    {_counter, fn_specs} = acc
    lifted_ir = %{ir | states: states, anystate: anystate, properties: properties}
    {lifted_ir, Enum.reverse(fn_specs)}
  end

  defp lift_transition_list(transitions, module, acc) do
    Enum.map_reduce(transitions, acc, fn transition, acc ->
      {guard, acc} = lift_fun_pair(transition.guard, module, acc)
      {update, acc} = lift_fun_pair(transition.update, module, acc)
      {branches, acc} = lift_branch_list(transition.branches, module, acc)
      {%{transition | guard: guard, update: update, branches: branches}, acc}
    end)
  end

  defp lift_branch_list(branches, module, acc) do
    Enum.map_reduce(branches, acc, fn branch, acc ->
      {constraint, acc} = lift_fun_pair(branch.constraint, module, acc)
      {%{branch | constraint: constraint}, acc}
    end)
  end

  defp lift_fun_pair(nil, _module, acc), do: {nil, acc}

  defp lift_fun_pair(%{fun: _fun, ast: ast} = pair, module, {counter, fn_specs}) do
    name = :"__accord_fn_#{counter}__"
    arity = fn_arity(ast)
    capture = Function.capture(module, name, arity)
    {%{pair | fun: capture}, {counter + 1, [{name, arity, ast} | fn_specs]}}
  end

  defp lift_property_list(properties, module, acc) do
    Enum.map_reduce(properties, acc, fn property, acc ->
      {checks, acc} = lift_check_list(property.checks, module, acc)
      {%{property | checks: checks}, acc}
    end)
  end

  defp lift_check_list(checks, module, acc) do
    Enum.map_reduce(checks, acc, fn check, acc ->
      {spec, acc} = lift_check_spec(check.kind, check.spec, module, acc)
      {%{check | spec: spec}, acc}
    end)
  end

  defp lift_check_spec(kind, %{fun: _fun, ast: ast} = spec, module, {counter, fn_specs})
       when kind in [:invariant, :local_invariant, :action, :forbidden] do
    name = :"__accord_fn_#{counter}__"
    arity = fn_arity(ast)
    capture = Function.capture(module, name, arity)
    {%{spec | fun: capture}, {counter + 1, [{name, arity, ast} | fn_specs]}}
  end

  defp lift_check_spec(_kind, spec, _module, acc), do: {spec, acc}

  defp fn_arity({:fn, _, [{:->, _, [args, _]} | _]}), do: length(args)

  # -- Fn AST → Def AST --

  defp fn_to_defs(fn_specs) do
    Enum.flat_map(fn_specs, fn {name, _arity, {:fn, _, clauses}} ->
      Enum.map(clauses, fn {:->, _, [args, body]} ->
        {def_args, guards} = extract_fn_guard(args)
        head = {name, [], def_args}

        case guards do
          nil ->
            quote do
              @doc false
              def unquote(head), do: unquote(body)
            end

          _ ->
            quote do
              @doc false
              def unquote({:when, [], [head | guards]}), do: unquote(body)
            end
        end
      end)
    end)
  end

  # Extracts guard expressions from fn clause args.
  # In `fn a, b when is_integer(a) -> ...`, the last arg is
  # {:when, _, [last_pattern | guard_exprs]}.
  defp extract_fn_guard([]), do: {[], nil}

  defp extract_fn_guard(args) do
    case List.last(args) do
      {:when, _, [last_arg | guards]} ->
        {Enum.slice(args, 0..-2//1) ++ [last_arg], guards}

      _ ->
        {args, nil}
    end
  end

  # -- Message Spec Parsing --

  @doc false
  def parse_message_spec(spec) when is_atom(spec), do: {spec, [], [], []}

  # Variable reference (bare atom at macro time).
  def parse_message_spec({tag, _, nil}) when is_atom(tag), do: {tag, [], [], []}

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

    parsed =
      Enum.map(rest, fn
        {:"::", _, [{name, _, _}, type_ast]} when is_atom(name) ->
          {IR.Type.parse(type_ast), Atom.to_string(name), type_span(type_ast)}

        type_ast ->
          {IR.Type.parse(type_ast), nil, nil}
      end)

    types = Enum.map(parsed, &elem(&1, 0))
    arg_names = Enum.map(parsed, &elem(&1, 1))
    arg_spans = Enum.map(parsed, &elem(&1, 2))

    pattern =
      case length(types) do
        0 -> tag_value
        1 -> {tag_value, :_}
        _ -> {:{}, [], [tag_value | List.duplicate(:_, length(types))]}
      end

    {pattern, types, arg_names, arg_spans}
  end

  defp type_span({_, meta, _} = type_ast) when is_list(meta) do
    case Keyword.get(meta, :line) do
      nil ->
        nil

      line ->
        %Pentiment.Span.Search{line: line, pattern: Macro.to_string(type_ast)}
    end
  end

  defp type_span(_), do: nil

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

  @doc false
  def span_ast(caller) do
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

  # Builds a search span covering the full message spec text.
  defp message_span_ast(message_spec, caller) do
    pattern = Macro.to_string(message_spec)
    line = caller.line

    quote do
      Pentiment.Span.search(line: unquote(line), pattern: unquote(pattern))
    end
  end

  # Builds a deferred search span that finds the property name atom
  # on the declaration line at format time.
  defp span_from_name_ast(name, caller) do
    pattern = inspect(name)
    line = caller.line

    quote do
      Pentiment.Span.search(line: unquote(line), pattern: unquote(pattern))
    end
  end
end
