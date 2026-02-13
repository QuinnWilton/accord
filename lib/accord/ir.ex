defmodule Accord.IR do
  @moduledoc """
  Intermediate representation for a protocol specification.

  The single source of truth consumed by both the downward pipeline
  (gen_statem monitor) and the upward pipeline (TLA+ spec). Every node
  carries an optional `Pentiment.Span.t()` for diagnostics.
  """

  alias Accord.IR.{Property, Role, State, Track, Transition}

  @type t :: %__MODULE__{
          name: module(),
          source_file: String.t() | nil,
          initial: atom(),
          roles: [Role.t()],
          tracks: [Track.t()],
          states: %{atom() => State.t()},
          anystate: [Transition.t()],
          properties: [Property.t()]
        }

  @enforce_keys [:name, :initial]
  defstruct [
    :name,
    :source_file,
    :initial,
    roles: [],
    tracks: [],
    states: %{},
    anystate: [],
    properties: []
  ]
end
