defmodule GuideBoardLifecycle.DrawStroke.StrokeDrawnV1 do
  # Event: stroke_drawn_v1.
  @behaviour :evoq_event

  alias GuideBoardLifecycle.DrawStroke.DrawStrokeV1

  defstruct [:board_id, :stroke_id, :points, :color, :width, :drawn_at]

  @impl true
  def event_type, do: "stroke_drawn_v1"

  @impl true
  def new(%{board_id: id, stroke_id: sid, points: points, color: color, width: width}) do
    %__MODULE__{
      board_id: id,
      stroke_id: sid,
      points: points,
      color: color,
      width: width,
      drawn_at: System.system_time(:millisecond)
    }
  end

  def from_command(%DrawStrokeV1{} = cmd) do
    new(%{
      board_id: DrawStrokeV1.board_id(cmd),
      stroke_id: DrawStrokeV1.stroke_id(cmd),
      points: DrawStrokeV1.points(cmd),
      color: DrawStrokeV1.color(cmd),
      width: DrawStrokeV1.width(cmd)
    })
  end

  @impl true
  def to_map(%__MODULE__{} = e) do
    %{
      event_type: event_type(),
      board_id: e.board_id,
      stroke_id: e.stroke_id,
      points: e.points,
      color: e.color,
      width: e.width,
      drawn_at: e.drawn_at
    }
  end

  def board_id(%__MODULE__{board_id: v}), do: v
end
