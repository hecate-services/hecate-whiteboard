defmodule ProjectBoards.ShapeMutatedToBoardShapes.ShapeMutatedToBoardShapes do
  # Projects sticky_placed_v1/text_placed_v1/shape_moved_v1/
  # shape_removed_v1 onto the `board_shapes` ETS bag -- mirrors
  # BoardLifecycleToBoards' own "several event types, one read model"
  # shape (see that module's header for why :evoq_event_handler, not
  # :evoq_projection).
  #
  # sticky/text placement normalizes x/y into a one-element `points` list
  # so every board_shapes row -- stroke, sticky, or text -- carries
  # `points` uniformly. See Store.move_shape/3's own header for why that
  # uniformity is what makes move/remove kind-agnostic.
  @behaviour :evoq_event_handler

  alias ProjectBoards.Store

  @impl true
  def interested_in,
    do: ["sticky_placed_v1", "text_placed_v1", "shape_moved_v1", "shape_removed_v1"]

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

  def handle_event("shape_moved_v1", event, _metadata, state) do
    data = field(:data, event)
    board_id = field(:board_id, data)
    shape_id = field(:shape_id, data)
    points = field(:points, data)

    Store.move_shape(board_id, shape_id, points)
    broadcast(board_id, {:shape_moved, %{shape_id: shape_id, points: points}})

    {:ok, state}
  end

  def handle_event(event_type, event, _metadata, state) do
    data = field(:data, event)
    board_id = field(:board_id, data)
    shape = to_shape(event_type, data)

    :ets.insert(Store.board_shapes_table(), {board_id, shape})
    broadcast(board_id, {:shape_placed, shape})

    {:ok, state}
  end

  defp to_shape("sticky_placed_v1", data) do
    %{
      kind: "sticky",
      shape_id: field(:shape_id, data),
      points: [%{x: field(:x, data), y: field(:y, data)}],
      color: field(:color, data),
      text: field(:text, data)
    }
  end

  defp to_shape("text_placed_v1", data) do
    %{
      kind: "text",
      shape_id: field(:shape_id, data),
      points: [%{x: field(:x, data), y: field(:y, data)}],
      color: field(:color, data),
      text: field(:text, data)
    }
  end

  defp broadcast(board_id, message),
    do: Phoenix.PubSub.broadcast(HecateWhiteboardWeb.PubSub, "board:" <> board_id, message)

  defp field(key, map) when is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end
end
