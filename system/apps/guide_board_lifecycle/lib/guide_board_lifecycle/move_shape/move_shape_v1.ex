defmodule GuideBoardLifecycle.MoveShape.MoveShapeV1 do
  # Command: move_shape_v1 -- repositions an existing shape (stroke,
  # sticky, or text label) by replacing its points wholesale with a new
  # absolute list. Works identically across shape kinds because every
  # shape kind already stores its position(s) as a points list: a stroke
  # has many points, a sticky/text label has exactly one (its anchor) --
  # see ProjectBoards.Store's own note on the unified board_shapes row
  # shape. The client computes the new list by applying the SAME drag
  # delta to every point the shape already had, so this command carries
  # no separate "delta" concept to keep in sync with drift.
  @behaviour :evoq_command

  defstruct [:board_id, :shape_id, :points]

  @impl true
  def command_type, do: :move_shape

  @impl true
  def new(%{board_id: board_id, shape_id: shape_id, points: points})
      when is_binary(board_id) and board_id != "" and is_binary(shape_id) and shape_id != "" and
             is_list(points) and points != [] do
    {:ok, %__MODULE__{board_id: board_id, shape_id: shape_id, points: points}}
  end

  def new(_), do: {:error, :board_id_shape_id_and_points_required}

  @impl true
  def to_map(%__MODULE__{} = cmd),
    do: %{
      command_type: command_type(),
      board_id: cmd.board_id,
      shape_id: cmd.shape_id,
      points: cmd.points
    }

  @impl true
  def from_map(%{board_id: id, shape_id: sid, points: points}),
    do: {:ok, %__MODULE__{board_id: id, shape_id: sid, points: points}}

  def from_map(_), do: {:error, :missing_required_fields}

  def board_id(%__MODULE__{board_id: v}), do: v
  def shape_id(%__MODULE__{shape_id: v}), do: v
  def points(%__MODULE__{points: v}), do: v
end
