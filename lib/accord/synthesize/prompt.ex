defmodule Accord.Synthesize.Prompt do
  @moduledoc """
  Prompt templates for LLM-driven protocol synthesis.

  Builds structured prompts in three layers:
  1. **Structural context** — facts from `Accord.Synthesize.Extractor`
  2. **Source code** — the full Elixir source of the target module
  3. **Target schema with examples** — Accord DSL reference and worked examples

  Also provides refinement prompt builders for feeding validation errors
  and TLC counterexamples back to the LLM.
  """

  alias Accord.Synthesize.Extractor

  @type facts :: Extractor.facts()

  @doc """
  Build the initial synthesis prompt from extracted facts and source code.
  """
  @spec build(facts(), String.t()) :: String.t()
  def build(facts, source) do
    [
      system_preamble(),
      dsl_reference(),
      worked_example(),
      task_section(facts, source)
    ]
    |> Enum.join("\n\n")
  end

  @doc """
  Build a refinement prompt for Accord validation errors (Channel 1).

  Appends error diagnostics to the original context so the LLM can fix
  structural issues in the synthesized protocol.
  """
  @spec build_validation_refinement(String.t(), String.t(), facts(), String.t()) :: String.t()
  def build_validation_refinement(protocol_source, errors, facts, source) do
    [
      system_preamble(),
      dsl_reference(),
      task_section(facts, source),
      """
      ## Previous Attempt

      You previously generated this protocol, but it has validation errors.
      Fix the errors and output a corrected protocol.

      ### Generated Protocol (with errors)

      ```elixir
      #{protocol_source}
      ```

      ### Validation Errors

      #{errors}

      Output only the corrected protocol module definition in a single elixir code block.
      """
    ]
    |> Enum.join("\n\n")
  end

  @doc """
  Build a refinement prompt for TLC model checking counterexamples (Channel 2).

  Includes the counterexample trace so the LLM can identify whether the
  protocol is over-constrained or under-constrained.
  """
  @spec build_tlc_refinement(String.t(), String.t(), facts(), String.t()) :: String.t()
  def build_tlc_refinement(protocol_source, violation_report, facts, source) do
    [
      system_preamble(),
      dsl_reference(),
      task_section(facts, source),
      """
      ## Previous Attempt

      You previously generated this protocol. It passed validation but TLC
      model checking found a counterexample. Fix the protocol and output a
      corrected version.

      ### Generated Protocol

      ```elixir
      #{protocol_source}
      ```

      ### TLC Counterexample

      #{violation_report}

      This means the protocol is either over-constrained (a property is too strong)
      or under-constrained (missing a guard or transition). Consult the source code
      to determine which, then output the corrected protocol module definition in a
      single elixir code block.
      """
    ]
    |> Enum.join("\n\n")
  end

  @doc """
  Extract the first Elixir code block from an LLM response.

  Looks for a fenced code block with the `elixir` language tag. Returns
  the content between the fences, or the full response if no code block
  is found (defensive — some LLMs omit fences).
  """
  @spec extract_code_block(String.t()) :: String.t()
  def extract_code_block(response) do
    case Regex.run(~r/```elixir\n(.*?)```/s, response) do
      [_, code] -> String.trim(code)
      nil -> extract_generic_code_block(response)
    end
  end

  defp extract_generic_code_block(response) do
    case Regex.run(~r/```\n(.*?)```/s, response) do
      [_, code] -> String.trim(code)
      nil -> String.trim(response)
    end
  end

  # -- Prompt Sections --

  defp system_preamble do
    """
    You are a protocol synthesis engine. Given an OTP module's source code and
    structural analysis facts, synthesize an Accord protocol definition that
    captures the module's message-passing contract.

    Output a single Elixir code block containing the complete protocol module
    definition. Do not include the server implementation — only the protocol.
    """
  end

  defp dsl_reference do
    """
    ## Accord Protocol DSL Reference

    An Accord protocol defines a state machine contract between client and server.

    ```elixir
    defmodule Example.Protocol do
      use Accord.Protocol

      initial :state_name              # required: starting state

      track :name, :type, default: val # named state accumulator

      state :name do                   # state with transitions
        # Synchronous call (client sends, server replies):
        on {:msg, arg :: type()}, reply: reply_type(), goto: :next

        # Call with block form (for guards, updates, branching):
        on {:msg, arg :: type()} do
          reply(reply_type())          # or: branch :ok, goto: :s1
          goto :next                   #     branch :error, goto: :s2
          guard fn {_msg, arg}, tracks -> bool end
          update fn {_msg, arg}, reply, tracks -> new_tracks end
        end

        # Asynchronous cast (fire-and-forget):
        cast :msg, goto: :next
      end

      state :done, terminal: true      # no outgoing transitions

      anystate do                      # valid in ALL non-terminal states
        on :ping, reply: :pong
      end

      property :name do                # behavioral properties
        invariant fn tracks -> bool end
        invariant :state, fn _msg, tracks -> bool end
        action fn old_tracks, new_tracks -> bool end
        correspondence :open_event, [:close_event]
        bounded :track, max: N
        liveness in_state(:trigger), leads_to: in_state(:target)
      end
    end
    ```

    ### Available types

    `:string`, `:integer`, `:pos_integer`, `:non_neg_integer`, `:atom`,
    `:binary`, `:boolean`, `:term`, `:map`

    Compound: `{:list, t}`, `{:tuple, [t]}`, `{:literal, val}`,
    `{:union, [t]}`, `{:tagged, atom, t}`

    In the DSL, types are written as type annotations on message arguments:
    `arg :: pos_integer()`, `name :: atom()`, `items :: [integer()]`

    Reply types use the same syntax: `reply: {:ok, integer()}`, `reply: :pong`

    ### Key rules

    - Every protocol must have `initial :state_name`.
    - Terminal states have no outgoing transitions.
    - Anystate transitions stay in the current state (no `goto:`).
    - Each `(state, message_tag)` pair must be unambiguous. Use guards or
      branching to handle different outcomes for the same message.
    - Call transitions (`on`) must have a reply type. Cast transitions (`cast`)
      have no reply.
    - Properties are optional but valuable. Only propose properties that the
      source code clearly supports.
    """
  end

  defp worked_example do
    """
    ## Worked Example

    ### Input: GenServer Source

    ```elixir
    defmodule Accord.Test.Counter.Server do
      use GenServer

      def start_link(opts \\\\ []) do
        initial = Keyword.get(opts, :initial, 0)
        GenServer.start_link(__MODULE__, initial, opts)
      end

      @impl true
      def init(initial), do: {:ok, initial}

      @impl true
      def handle_call({:increment, amount}, _from, count) do
        new = count + amount
        {:reply, {:ok, new}, new}
      end

      def handle_call({:decrement, amount}, _from, count) do
        new = count - amount
        {:reply, {:ok, new}, new}
      end

      def handle_call(:get, _from, count), do: {:reply, {:value, count}, count}
      def handle_call(:reset, _from, _count), do: {:reply, {:ok, 0}, 0}
      def handle_call(:stop, _from, count), do: {:reply, :stopped, count}
      def handle_call(:ping, _from, count), do: {:reply, :pong, count}

      @impl true
      def handle_cast(:heartbeat, count), do: {:noreply, count}
    end
    ```

    ### Structural Facts

    ```
    Module: Accord.Test.Counter.Server
    Behavior: GenServer
    Exports: start_link/1, init/1, handle_call/3, handle_cast/2
    Source: test/support/protocols/counter.ex
    ```

    ### Reasoning

    1. **States**: This GenServer has no explicit mode/state field. All handle_call
       clauses operate uniformly on the counter value. It has a single logical
       state (:ready) plus :stopped (after :stop returns :stopped and there are
       no further transitions).

    2. **Messages**:
       - {:increment, amount} — amount is pos_integer (from usage context)
       - {:decrement, amount} — amount is pos_integer
       - :get — no arguments
       - :reset — no arguments
       - :stop — no arguments
       - :ping — available in any state (stateless query)
       - :heartbeat — cast, available in any state

    3. **Reply types**:
       - {:increment, _} → {:ok, integer()}
       - {:decrement, _} → {:ok, integer()}
       - :get → {:value, integer()}
       - :reset → {:ok, integer()} (always returns {:ok, 0})
       - :stop → :stopped
       - :ping → :pong

    4. **Properties**: None strongly suggested by the code. A user might want
       monotonicity on increment, but decrement exists, so that doesn't hold.

    ### Output: Accord Protocol

    ```elixir
    defmodule Accord.Test.Counter.Protocol do
      use Accord.Protocol

      initial :ready

      state :ready do
        on {:increment, amount :: pos_integer()}, reply: {:ok, integer()}, goto: :ready
        on {:decrement, amount :: pos_integer()}, reply: {:ok, integer()}, goto: :ready
        on :get, reply: {:value, integer()}, goto: :ready
        on :reset, reply: {:ok, integer()}, goto: :ready
        on :stop, reply: :stopped, goto: :stopped
      end

      state :stopped, terminal: true

      anystate do
        on :ping, reply: :pong
        cast :heartbeat
      end
    end
    ```
    """
  end

  defp task_section(facts, source) do
    """
    ## Your Task

    Given the following OTP module source code and structural analysis facts,
    synthesize an Accord protocol definition. Follow the reasoning steps shown
    in the example:

    1. Identify logical states (for gen_statem: explicit; for GenServer: infer
       from state shape, mode fields, or uniform behavior)
    2. Enumerate messages per state from callback pattern matching
    3. Determine argument types from patterns and guards
    4. Determine reply types from callback return values
    5. Identify transitions (which state after handling each message)
    6. Note anystate messages (handled identically in all states)
    7. Propose properties if the code suggests invariants, monotonicity,
       correspondence, or liveness patterns
    8. Assemble the protocol definition

    ### Structural Facts

    ```
    #{format_facts(facts)}
    ```

    ### Source Code

    ```elixir
    #{source}
    ```

    Reason step by step, then output the complete protocol module definition
    in a single elixir code block.
    """
  end

  # -- Fact Formatting --

  defp format_facts(facts) do
    lines = [
      "Module: #{inspect(facts.module)}",
      "Behavior: #{format_behaviour(facts.behaviour)}",
      format_callback_mode(facts.callback_mode),
      format_states(facts.states),
      format_transitions(facts.transitions),
      format_timeouts(facts.timeouts),
      format_api("Sync API", facts.sync_calls),
      format_api("Async API", facts.async_casts),
      format_exports(facts.exports),
      format_source_file(facts.source_file)
    ]

    lines
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp format_behaviour(:gen_server), do: "GenServer"
  defp format_behaviour(:gen_statem), do: "gen_statem"
  defp format_behaviour(nil), do: "unknown"

  defp format_callback_mode(nil), do: nil
  defp format_callback_mode(mode), do: "Callback mode: #{mode}"

  defp format_states([]), do: nil
  defp format_states(states), do: "States: #{inspect(states)}"

  defp format_transitions([]), do: nil

  defp format_transitions(transitions) do
    lines =
      Enum.map(transitions, fn {from, event, to} ->
        "  #{from} --[#{event}]--> #{to}"
      end)

    "Transitions:\n#{Enum.join(lines, "\n")}"
  end

  defp format_timeouts([]), do: nil

  defp format_timeouts(timeouts) do
    lines =
      Enum.map(timeouts, fn {state, type, value} ->
        "  #{state}: #{type} = #{value}ms"
      end)

    "Timeouts:\n#{Enum.join(lines, "\n")}"
  end

  defp format_api(_label, []), do: nil

  defp format_api(label, functions) do
    "#{label}: #{Enum.join(functions, ", ")}"
  end

  defp format_exports([]), do: nil

  defp format_exports(exports) do
    formatted =
      exports
      |> Enum.map(fn {name, arity} -> "#{name}/#{arity}" end)
      |> Enum.join(", ")

    "Exports: #{formatted}"
  end

  defp format_source_file(nil), do: nil
  defp format_source_file(path), do: "Source: #{path}"
end
