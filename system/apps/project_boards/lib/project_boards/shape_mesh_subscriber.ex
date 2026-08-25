defmodule ProjectBoards.ShapeMeshSubscriber do
  # :macula_subscriber callback for the shared shape_mutated_v1 topic
  # (sticky_placed_v1/text_placed_v1/shape_moved_v1/shape_removed_v1/
  # geometry_drawn_v1 -- see
  # GuideBoardLifecycle.ShapeMutation.ShapeMutatedV1ToMesh, the other
  # half of this pair, same topic string). Applies straight into the read
  # model, mirrors BoardMeshSubscriber's own loop-free reasoning: never
  # re-enters this host's own aggregate, so it can never trigger the mesh
  # emitter again.
  @behaviour :macula_subscriber

  alias ProjectBoards.Store

  @topic "io.macula/whiteboard-commons/whiteboard/shape_mutated_v1"

  def topic, do: @topic

  @impl true
  def init(_args), do: {:ok, nil}

  @impl true
  def handle_event(@topic, payload, _meta, state) when is_map(payload) do
    fact = normalize(payload)
    board_id = field(:board_id, fact)
    shape_id = field(:shape_id, fact)

    case field(:event_type, fact) do
      "shape_removed_v1" ->
        Store.remove_shape(board_id, shape_id)
        broadcast(board_id, {:shape_removed, shape_id})

      "shape_moved_v1" ->
        points = field(:points, fact)
        Store.move_shape(board_id, shape_id, points)
        broadcast(board_id, {:shape_moved, %{shape_id: shape_id, points: points}})

      "sticky_placed_v1" ->
        place(board_id, "sticky", fact)

      "text_placed_v1" ->
        place(board_id, "text", fact)

      "geometry_drawn_v1" ->
        place_geometry(board_id, fact)

      _other ->
        :ok
    end

    {:noreply, state}
  end

  def handle_event(_topic, _payload, _meta, state), do: {:noreply, state}

  # Guards against a peer's own catchup-replay restart re-publishing its
  # full local history to this topic -- same reasoning as
  # BoardMeshSubscriber's own new_shape? guard for strokes, just shared
  # across every non-stroke kind too (see Store's module doc).
  defp place(board_id, kind, fact) do
    shape = %{
      kind: kind,
      shape_id: field(:shape_id, fact),
      points: [%{x: field(:x, fact), y: field(:y, fact)}],
      color: field(:color, fact),
      text: field(:text, fact)
    }

    if Store.new_shape?(shape.shape_id) do
      :ets.insert(Store.board_shapes_table(), {board_id, shape})
      broadcast(board_id, {:shape_placed, shape})
    end
  end

  defp place_geometry(board_id, fact) do
    shape = %{
      kind: field(:kind, fact),
      shape_id: field(:shape_id, fact),
      points: field(:points, fact),
      color: field(:color, fact)
    }

    if Store.new_shape?(shape.shape_id) do
      :ets.insert(Store.board_shapes_table(), {board_id, shape})
      broadcast(board_id, {:shape_placed, shape})
    end
  end

  defp broadcast(board_id, message),
    do: Phoenix.PubSub.broadcast(HecateWhiteboardWeb.PubSub, "board:" <> board_id, message)

  # Same atom-vs-{text,_} tolerance every mesh receiver in this repo
  # needs -- see BoardMeshSubscriber's own comment for the full story.
  defp field(key, map) when is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp normalize({:text, b}) when is_binary(b), do: b
  defp normalize(:undefined), do: nil
  defp normalize(m) when is_map(m), do: Map.new(m, fn {k, v} -> {normalize(k), normalize(v)} end)
  defp normalize(l) when is_list(l), do: Enum.map(l, &normalize/1)
  defp normalize(v), do: v
end
