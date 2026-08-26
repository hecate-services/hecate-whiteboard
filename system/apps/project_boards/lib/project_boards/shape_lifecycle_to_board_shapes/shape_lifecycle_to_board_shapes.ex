defmodule ProjectBoards.ShapeLifecycleToBoardShapes.ShapeLifecycleToBoardShapes do
  # Projects shape_initiated_v1/shape_amended_v1/shape_removed_v1 onto
  # the `board_shapes` ETS bag -- replaces StrokeDrawnV1ToBoardShapes AND
  # ShapeMutatedToBoardShapes, which each existed only because shape
  # creation used to be four separate event types (stroke_drawn_v1/
  # sticky_placed_v1/text_placed_v1/geometry_drawn_v1), each needing its
  # own per-kind field mapping (to_shape/2's own dispatch). Now that
  # every kind arrives through the SAME event with `kind` as data, that
  # whole dispatch collapses: the row is built directly off the event's
  # own fields, no per-kind branching left to get wrong.
  #
  # No more `stroke_id` field on the row either -- it was always exactly
  # equal to `shape_id` for a stroke (see the old Store module doc), and
  # nothing downstream (JS client, this app, query_boards) ever read it
  # as distinct from shape_id. Confirmed by grep before dropping it.
  @behaviour :evoq_event_handler

  alias ProjectBoards.Store

  @impl true
  def interested_in, do: ["shape_initiated_v1", "shape_amended_v1", "shape_removed_v1"]

  @impl true
  def init(_config), do: {:ok, %{}}

  @impl true
  def handle_event("shape_removed_v1", event, _metadata, state) do
    data = field(:data, event)
    board_id = field(:board_id, data)
    shape_id = field(:shape_id, data)

    Store.remove_shape(board_id, shape_id)
    broadcast(board_id, {:shape_removed, shape_id})

    {:ok, state}
  end

  def handle_event("shape_amended_v1", event, _metadata, state) do
    data = field(:data, event)
    board_id = field(:board_id, data)
    shape_id = field(:shape_id, data)
    points = field(:points, data)

    Store.move_shape(board_id, shape_id, points)
    broadcast(board_id, {:shape_moved, %{shape_id: shape_id, points: points}})

    {:ok, state}
  end

  # Guards against evoq's catchup replay on restart re-delivering this
  # host's own full local history -- see Store's module doc for why.
  # shape_amended_v1/shape_removed_v1 above don't need this: they act on
  # an ALREADY-STORED shape via Store.move_shape/remove_shape (a
  # find-then-replace, safe to repeat), whereas this clause inserts a
  # brand new row every call.
  def handle_event("shape_initiated_v1", event, _metadata, state) do
    data = field(:data, event)
    board_id = field(:board_id, data)

    shape = %{
      kind: field(:kind, data),
      shape_id: field(:shape_id, data),
      points: field(:points, data),
      color: field(:color, data),
      width: field(:width, data),
      text: field(:text, data),
      from_shape_id: field(:from_shape_id, data),
      to_shape_id: field(:to_shape_id, data)
    }

    if Store.new_shape?(shape.shape_id) do
      :ets.insert(Store.board_shapes_table(), {board_id, shape})
      # `version` is on the wrapped event itself, not under `data` -- see
      # "Event shape on the wire" in the plan doc. Feeds join_board's
      # as_of_version (Store's own module doc explains why).
      Store.note_shape_version(board_id, field(:version, event))
      broadcast(board_id, {:shape_placed, shape})
    end

    {:ok, state}
  end

  defp broadcast(board_id, message),
    do: Phoenix.PubSub.broadcast(HecateWhiteboardWeb.PubSub, "board:" <> board_id, message)

  defp field(key, map) when is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end
end
