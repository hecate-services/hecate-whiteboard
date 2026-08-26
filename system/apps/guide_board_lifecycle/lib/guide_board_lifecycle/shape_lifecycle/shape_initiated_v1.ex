defmodule GuideBoardLifecycle.ShapeLifecycle.ShapeInitiatedV1 do
  # Event: shape_initiated_v1 -- the ONE event every shape kind
  # (stroke/sticky/text/rectangle/ellipse/triangle) is created through.
  # Replaces four separate creation events this desk family used to
  # produce (stroke_drawn_v1, sticky_placed_v1, text_placed_v1,
  # geometry_drawn_v1), each with its own near-identical shape. That
  # duplication is exactly what caused a real bug:
  # GetBoardSnapshotByIdOverMesh's own normalize_stroke/1 only knew how
  # to extract stroke_id/points/color/width, so kind/shape_id/text got
  # silently dropped for every other kind. One event, `kind` as DATA
  # instead of as four different event NAMES, closes the whole bug
  # class instead of just that one instance. Not every field applies to
  # every kind (width only for stroke, text only for sticky/text) --
  # nil where it doesn't, same as the read-model row shape
  # ProjectBoards.Store's own header already documents.
  #
  # Four DIFFERENT commands (draw_stroke/place_sticky/place_text/
  # draw_geometry) still exist and still do their own kind-specific
  # validation -- they're genuinely different user-facing actions with
  # different required inputs. Only the EVENT they end up producing is
  # shared, so there's no single from_command/1 here -- each Maybe*
  # handler builds the fields map itself from its own command struct.
  #
  # from_shape_id/to_shape_id (arrow only): which two shapes an arrow
  # connects, so every viewer can recompute its CURRENT path from
  # wherever those shapes are NOW -- not fixed points frozen at creation.
  # `points` still carries the two endpoints as they were at creation
  # time regardless of kind: for an arrow this is a FALLBACK only, used
  # when a referenced shape_id can't be resolved (removed, or a
  # freestanding endpoint with no shape_id at all). Moving/resizing a
  # shape that an arrow points to costs nothing extra here -- the arrow
  # itself is never re-emitted, its renderer just resolves the
  # reference fresh on every draw. Same "computed live, nothing stored
  # as a relationship" trick draw_geometry's own frame kind already
  # uses for containment.
  @behaviour :evoq_event

  defstruct [
    :board_id,
    :shape_id,
    :kind,
    :points,
    :color,
    :width,
    :text,
    :from_shape_id,
    :to_shape_id,
    :initiated_at
  ]

  @impl true
  def event_type, do: "shape_initiated_v1"

  @impl true
  def new(%{board_id: id, shape_id: sid, kind: kind, points: points, color: color} = fields) do
    %__MODULE__{
      board_id: id,
      shape_id: sid,
      kind: kind,
      points: points,
      color: color,
      width: Map.get(fields, :width),
      text: Map.get(fields, :text),
      from_shape_id: Map.get(fields, :from_shape_id),
      to_shape_id: Map.get(fields, :to_shape_id),
      initiated_at: System.system_time(:millisecond)
    }
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
      width: e.width,
      text: e.text,
      from_shape_id: e.from_shape_id,
      to_shape_id: e.to_shape_id,
      initiated_at: e.initiated_at
    }
  end

  def board_id(%__MODULE__{board_id: v}), do: v
end
