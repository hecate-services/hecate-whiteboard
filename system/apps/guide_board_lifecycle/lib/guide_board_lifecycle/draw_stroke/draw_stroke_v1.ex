defmodule GuideBoardLifecycle.DrawStroke.DrawStrokeV1 do
  # Command: draw_stroke_v1 -- adds one freehand stroke to a hosted board.
  # stroke_id is a plain random id, not a reckon_gater stream id -- a
  # stroke isn't its own aggregate/stream, just a value inside the board's.
  @behaviour :evoq_command

  defstruct [:board_id, :stroke_id, :points, :color, :width]

  @impl true
  def command_type, do: :draw_stroke

  @impl true
  def new(%{board_id: board_id, points: points} = params)
      when is_binary(board_id) and board_id != "" and is_list(points) and points != [] do
    {:ok,
     %__MODULE__{
       board_id: board_id,
       stroke_id: random_id(),
       points: points,
       color: Map.get(params, :color, "#f2efe6"),
       width: Map.get(params, :width, 3)
     }}
  end

  def new(_), do: {:error, :board_id_and_points_required}

  @impl true
  def to_map(%__MODULE__{} = cmd) do
    %{
      command_type: command_type(),
      board_id: cmd.board_id,
      stroke_id: cmd.stroke_id,
      points: cmd.points,
      color: cmd.color,
      width: cmd.width
    }
  end

  @impl true
  def from_map(%{board_id: id, stroke_id: sid, points: points, color: color, width: width}) do
    {:ok, %__MODULE__{board_id: id, stroke_id: sid, points: points, color: color, width: width}}
  end

  def from_map(_), do: {:error, :missing_required_fields}

  def board_id(%__MODULE__{board_id: v}), do: v
  def stroke_id(%__MODULE__{stroke_id: v}), do: v
  def points(%__MODULE__{points: v}), do: v
  def color(%__MODULE__{color: v}), do: v
  def width(%__MODULE__{width: v}), do: v

  defp random_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
