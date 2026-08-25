defmodule GuideBoardLifecycle.RemoveShape.ShapeRemovedV1 do
  # Event: shape_removed_v1.
  @behaviour :evoq_event

  alias GuideBoardLifecycle.RemoveShape.RemoveShapeV1

  defstruct [:board_id, :shape_id, :removed_at]

  @impl true
  def event_type, do: "shape_removed_v1"

  @impl true
  def new(%{board_id: id, shape_id: sid}) do
    %__MODULE__{board_id: id, shape_id: sid, removed_at: System.system_time(:millisecond)}
  end

  def from_command(%RemoveShapeV1{} = cmd) do
    new(%{board_id: RemoveShapeV1.board_id(cmd), shape_id: RemoveShapeV1.shape_id(cmd)})
  end

  @impl true
  def to_map(%__MODULE__{} = e) do
    %{
      event_type: event_type(),
      board_id: e.board_id,
      shape_id: e.shape_id,
      removed_at: e.removed_at
    }
  end

  def board_id(%__MODULE__{board_id: v}), do: v
end
