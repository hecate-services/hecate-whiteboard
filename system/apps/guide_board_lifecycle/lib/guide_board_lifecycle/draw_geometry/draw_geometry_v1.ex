defmodule GuideBoardLifecycle.DrawGeometry.DrawGeometryV1 do
  # Command: draw_geometry_v1 -- adds one basic shape (rectangle, ellipse,
  # triangle, or frame) to a hosted board. `points` is always the two
  # opposite corners of the shape's bounding box (client-computed from a
  # click-drag gesture, same convention every other drawing tool uses
  # for these three) -- the renderer derives the actual outline from
  # `kind` + those two points, so no shape-specific geometry needs to
  # travel over the wire. Outlined in the caller's ink color, not
  # filled -- reuses the Pen tool's palette rather than adding a second
  # color picker just for these three. `frame` (a grouping container --
  # any shape whose position falls within its bounds counts as
  # contained, computed live client-side, nothing stored server-side)
  # rides the exact same command/event -- it's still just a kind with
  # two corner points, the server has no notion of "container" at all.
  @behaviour :evoq_command

  @kinds ~w(rectangle ellipse triangle frame)

  defstruct [:board_id, :shape_id, :kind, :points, :color]

  @impl true
  def command_type, do: :draw_geometry

  @impl true
  def new(%{board_id: board_id, kind: kind, points: points} = params)
      when is_binary(board_id) and board_id != "" and kind in @kinds and is_list(points) and
             length(points) == 2 do
    {:ok,
     %__MODULE__{
       board_id: board_id,
       shape_id: random_id(),
       kind: kind,
       points: points,
       color: Map.get(params, :color, "#f2efe6")
     }}
  end

  def new(_), do: {:error, :board_id_kind_and_two_points_required}

  @impl true
  def to_map(%__MODULE__{} = cmd) do
    %{
      command_type: command_type(),
      board_id: cmd.board_id,
      shape_id: cmd.shape_id,
      kind: cmd.kind,
      points: cmd.points,
      color: cmd.color
    }
  end

  @impl true
  def from_map(%{board_id: id, shape_id: sid, kind: kind, points: points, color: color}) do
    {:ok, %__MODULE__{board_id: id, shape_id: sid, kind: kind, points: points, color: color}}
  end

  def from_map(_), do: {:error, :missing_required_fields}

  def board_id(%__MODULE__{board_id: v}), do: v
  def shape_id(%__MODULE__{shape_id: v}), do: v
  def kind(%__MODULE__{kind: v}), do: v
  def points(%__MODULE__{points: v}), do: v
  def color(%__MODULE__{color: v}), do: v

  defp random_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
