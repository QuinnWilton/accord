defmodule Accord.Pass.BuildTrackInit do
  @moduledoc """
  Produces initial track state from track declarations.
  """

  alias Accord.IR

  @spec run(IR.t()) :: {:ok, map()}
  def run(%IR{tracks: tracks}) do
    init =
      Map.new(tracks, fn track ->
        {track.name, track.default}
      end)

    {:ok, init}
  end
end
