defmodule GuideBoardLifecycle.BoardStatus do
  # Status is an integer bit flag, not an atom/string -- shared by
  # BoardAggregate (business rules) and BoardState (event application).
  # Mirrors hecate-tube's tube_channel_status.hrl, as a module instead of
  # an .hrl include since these are Elixir modules.
  @moduledoc false

  @initiated 1
  @archived 2
  @hosted 4

  def initiated, do: @initiated
  def archived, do: @archived
  def hosted, do: @hosted
end
