defmodule GuideBoardLifecycle.MoveShape.ShapeMovedV1 do
  # Event: shape_moved_v1.
  @behaviour :evoq_event

  alias GuideBoardLifecycle.MoveShape.MoveShapeV1

  defstruct [:board_id, :shape_id, :points, :moved_at]

  @impl true
  def event_type, do: "shape_moved_v1"

  @impl true
  def new(%{board_id: id, shape_id: sid, points: points}) do
    %__MODULE__{
      board_id: id,
      shape_id: sid,
      points: points,
      moved_at: System.system_time(:millisecond)
    }
  end

  def from_command(%MoveShapeV1{} = cmd) do
    new(%{
      board_id: MoveShapeV1.board_id(cmd),
      shape_id: MoveShapeV1.shape_id(cmd),
      points: MoveShapeV1.points(cmd)
    })
  end

  @impl true
  def to_map(%__MODULE__{} = e) do
    %{
      event_type: event_type(),
      board_id: e.board_id,
      shape_id: e.shape_id,
      points: e.points,
      moved_at: e.moved_at
    }
  end

  def board_id(%__MODULE__{board_id: v}), do: v
end
