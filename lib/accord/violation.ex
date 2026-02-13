defmodule Accord.Violation do
  @moduledoc """
  Represents a protocol violation with blame assignment.

  A violation is created when either the client or server breaks the
  protocol contract. The `blame` field indicates which side is responsible.

  ## Client violations

  - `:invalid_message` — sent a message not valid in current state.
  - `:argument_type` — message argument has wrong type.
  - `:guard_failed` — guard pre-condition returned false.
  - `:session_ended` — tried to send after terminal state.

  ## Server violations

  - `:invalid_reply` — reply doesn't match any branch type.
  - `:timeout` — server didn't respond in time.

  ## Property violations

  - `:invariant_violated` — a global or local invariant failed.
  - `:action_violated` — an action property (pre/post) failed.
  - `:liveness_violated` — a liveness timeout expired.
  """

  @type blame :: :client | :server | :property

  @type kind ::
          :invalid_message
          | :argument_type
          | :guard_failed
          | :session_ended
          | :invalid_reply
          | :timeout
          | :invariant_violated
          | :action_violated
          | :liveness_violated

  @type t :: %__MODULE__{
          blame: blame(),
          kind: kind(),
          protocol: module() | nil,
          state: atom(),
          message: term(),
          expected: term() | nil,
          reply: term() | nil,
          span: Pentiment.Span.t() | nil,
          stacktrace: Exception.stacktrace() | nil,
          context: map()
        }

  @enforce_keys [:blame, :kind, :state, :message]
  defstruct [
    :blame,
    :kind,
    :protocol,
    :state,
    :message,
    :expected,
    :reply,
    :span,
    :stacktrace,
    context: %{}
  ]

  @doc """
  Creates a client violation for a message not valid in current state.
  """
  @spec invalid_message(atom(), term(), list()) :: t()
  def invalid_message(state, message, expected) do
    %__MODULE__{
      blame: :client,
      kind: :invalid_message,
      state: state,
      message: message,
      expected: expected
    }
  end

  @doc """
  Creates a client violation for a wrong argument type.
  """
  @spec argument_type(atom(), term(), non_neg_integer(), term(), term()) :: t()
  def argument_type(state, message, position, expected_type, actual_value) do
    %__MODULE__{
      blame: :client,
      kind: :argument_type,
      state: state,
      message: message,
      expected: expected_type,
      context: %{
        position: position,
        expected_type: expected_type,
        actual_value: actual_value
      }
    }
  end

  @doc """
  Creates a client violation for a guard pre-condition failure.
  """
  @spec guard_failed(atom(), term()) :: t()
  def guard_failed(state, message) do
    %__MODULE__{
      blame: :client,
      kind: :guard_failed,
      state: state,
      message: message
    }
  end

  @doc """
  Creates a client violation for sending after the session ended.
  """
  @spec session_ended(atom(), term()) :: t()
  def session_ended(state, message) do
    %__MODULE__{
      blame: :client,
      kind: :session_ended,
      state: state,
      message: message,
      expected: :none
    }
  end

  @doc """
  Creates a server violation for an invalid reply.
  """
  @spec invalid_reply(atom(), term(), term(), list()) :: t()
  def invalid_reply(state, message, reply, valid_replies) do
    %__MODULE__{
      blame: :server,
      kind: :invalid_reply,
      state: state,
      message: message,
      reply: reply,
      context: %{valid_replies: valid_replies}
    }
  end

  @doc """
  Creates a timeout violation.
  """
  @spec timeout(atom(), term(), non_neg_integer(), blame()) :: t()
  def timeout(state, message, timeout_ms, blame \\ :server) do
    %__MODULE__{
      blame: blame,
      kind: :timeout,
      state: state,
      message: message,
      context: %{timeout_ms: timeout_ms}
    }
  end

  @doc """
  Creates a property violation for a global or local invariant failure.
  """
  @spec invariant_violated(atom(), atom(), map()) :: t()
  def invariant_violated(state, property_name, tracks) do
    %__MODULE__{
      blame: :property,
      kind: :invariant_violated,
      state: state,
      message: property_name,
      context: %{property: property_name, tracks: tracks}
    }
  end

  @doc """
  Creates a property violation for an action property failure.
  """
  @spec action_violated(atom(), atom(), map(), map()) :: t()
  def action_violated(state, property_name, old_tracks, new_tracks) do
    %__MODULE__{
      blame: :property,
      kind: :action_violated,
      state: state,
      message: property_name,
      context: %{property: property_name, old_tracks: old_tracks, new_tracks: new_tracks}
    }
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(violation, opts) do
      info = [
        blame: violation.blame,
        kind: violation.kind,
        state: violation.state,
        message: violation.message
      ]

      info =
        if violation.expected do
          info ++ [expected: violation.expected]
        else
          info
        end

      info =
        if violation.reply do
          info ++ [reply: violation.reply]
        else
          info
        end

      concat(["#Accord.Violation<", to_doc(info, opts), ">"])
    end
  end
end
