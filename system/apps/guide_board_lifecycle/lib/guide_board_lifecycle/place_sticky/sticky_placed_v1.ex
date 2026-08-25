defmodule GuideBoardLifecycle.PlaceSticky.StickyPlacedV1 do
  # Event: sticky_placed_v1.
  @behaviour :evoq_event

  alias GuideBoardLifecycle.PlaceSticky.PlaceStickyV1

  defstruct [:board_id, :shape_id, :x, :y, :color, :text, :placed_at]

  @impl true
  def event_type, do: "sticky_placed_v1"

  @impl true
  def new(%{board_id: id, shape_id: sid, x: x, y: y, color: color, text: text}) do
    %__MODULE__{
      board_id: id,
      shape_id: sid,
      x: x,
      y: y,
      color: color,
      text: text,
      placed_at: System.system_time(:millisecond)
    }
  end

  def from_command(%PlaceStickyV1{} = cmd) do
    new(%{
      board_id: PlaceStickyV1.board_id(cmd),
      shape_id: PlaceStickyV1.shape_id(cmd),
      x: PlaceStickyV1.x(cmd),
      y: PlaceStickyV1.y(cmd),
      color: PlaceStickyV1.color(cmd),
      text: PlaceStickyV1.text(cmd)
    })
  end

  @impl true
  def to_map(%__MODULE__{} = e) do
    %{
      event_type: event_type(),
      board_id: e.board_id,
      shape_id: e.shape_id,
      x: e.x,
      y: e.y,
      color: e.color,
      text: e.text,
      placed_at: e.placed_at
    }
  end

  def board_id(%__MODULE__{board_id: v}), do: v
end
