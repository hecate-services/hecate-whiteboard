defmodule ProjectBoards.StrokeDrawnV1ToBoardShapes.StrokeDrawnV1ToBoardShapes do
  # Projects stroke_drawn_v1 onto the `board_shapes` ETS bag (one entry per
  # stroke, keyed by board_id) and broadcasts the stroke so every live
  # LiveView on this board (including the one that just sent it) renders
  # it from the same server-confirmed path. See BoardLifecycleToBoards's
  # own header note for why this is :evoq_event_handler, not
  # :evoq_projection.
  @behaviour :evoq_event_handler

  alias ProjectBoards.Store

  @impl true
  def interested_in, do: ["stroke_drawn_v1"]

  @impl true
  def init(_config), do: {:ok, %{}}

  @impl true
  def handle_event("stroke_drawn_v1", event, _metadata, state) do
    data = field(:data, event)
    board_id = field(:board_id, data)
    stroke_id = field(:stroke_id, data)

    # Guards against evoq's catchup replay on restart re-delivering this
    # host's own full local history -- see Store's module doc for why.
    if Store.new_stroke?(stroke_id) do
      stroke = %{
        stroke_id: stroke_id,
        points: field(:points, data),
        color: field(:color, data),
        width: field(:width, data)
      }

      :ets.insert(Store.board_shapes_table(), {board_id, stroke})

      Phoenix.PubSub.broadcast(
        HecateWhiteboardWeb.PubSub,
        "board:" <> board_id,
        {:stroke_drawn, stroke}
      )
    end

    {:ok, state}
  end

  defp field(key, map) when is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end
end
