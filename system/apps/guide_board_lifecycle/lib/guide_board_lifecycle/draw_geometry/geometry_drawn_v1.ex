defmodule GuideBoardLifecycle.DrawGeometry.GeometryDrawnV1 do
  # Event: geometry_drawn_v1.
  @behaviour :evoq_event

  alias GuideBoardLifecycle.DrawGeometry.DrawGeometryV1

  defstruct [:board_id, :shape_id, :kind, :points, :color, :drawn_at]

  @impl true
  def event_type, do: "geometry_drawn_v1"

  @impl true
  def new(%{board_id: id, shape_id: sid, kind: kind, points: points, color: color}) do
    %__MODULE__{
      board_id: id,
      shape_id: sid,
      kind: kind,
      points: points,
      color: color,
      drawn_at: System.system_time(:millisecond)
    }
  end

  def from_command(%DrawGeometryV1{} = cmd) do
    new(%{
      board_id: DrawGeometryV1.board_id(cmd),
      shape_id: DrawGeometryV1.shape_id(cmd),
      kind: DrawGeometryV1.kind(cmd),
      points: DrawGeometryV1.points(cmd),
      color: DrawGeometryV1.color(cmd)
    })
  end

  @impl true
  def to_map(%__MODULE__{} = e) do
    %{
      event_type: event_type(),
      board_id: e.board_id,
      shape_id: e.shape_id,
      kind: e.kind,
      points: e.points,
      color: e.color,
      drawn_at: e.drawn_at
    }
  end

  def board_id(%__MODULE__{board_id: v}), do: v
end
