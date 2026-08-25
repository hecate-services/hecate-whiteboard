defmodule GuideBoardLifecycle.ShapeLifecycle.ShapeAmendedV1 do
  # Event: shape_amended_v1 -- an existing shape's state changed.
  # Replaces shape_moved_v1; renamed (not just "moved") so a future edit
  # that isn't a position change (recolor, retext, resize) has a home
  # without inventing yet another event name later -- though today
  # `points` (a move) is the only thing that ever changes, so that's
  # the only field this carries. Matches ShapeInitiatedV1's own
  # "X_initiated"/"X_amended" vocabulary, the same one board_initiated_v1/
  # board_hosted_v1/etc already established for boards.
  @behaviour :evoq_event

  alias GuideBoardLifecycle.MoveShape.MoveShapeV1

  defstruct [:board_id, :shape_id, :points, :amended_at]

  @impl true
  def event_type, do: "shape_amended_v1"

  @impl true
  def new(%{board_id: id, shape_id: sid, points: points}) do
    %__MODULE__{
      board_id: id,
      shape_id: sid,
      points: points,
      amended_at: System.system_time(:millisecond)
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
      amended_at: e.amended_at
    }
  end

  def board_id(%__MODULE__{board_id: v}), do: v
end
