defmodule ProjectBoards.ShapeLifecycleMeshSubscriber do
  # :macula_subscriber callback for the three shape-lifecycle facts
  # published by any peer hosting the same board_id (see
  # GuideBoardLifecycle.ShapeLifecycle.ShapeLifecycleV1ToMesh, the other
  # half of this pair -- three topic strings, must match). Replaces
  # BoardMeshSubscriber (stroke_drawn_v1's own topic) AND
  # ShapeMeshSubscriber (shape_mutated_v1's shared topic) -- same
  # collapse as ShapeLifecycleToBoardShapes on the local-projection side,
  # for the same reason: shape creation is one event type now, not four.
  #
  # Facts arrive as READ-ONLY: this writes straight into the ETS read
  # model and broadcasts locally exactly like the local
  # ShapeLifecycleToBoardShapes projection does, but it never dispatches
  # a command through this host's own aggregate. That is what keeps
  # replication loop-free -- a remote shape event never re-enters the
  # local evoq event log, so it can never trigger the mesh emitter again.
  @behaviour :macula_subscriber

  alias ProjectBoards.Store

  @topics [
    "io.macula/whiteboard-commons/whiteboard/shape_initiated_v1",
    "io.macula/whiteboard-commons/whiteboard/shape_amended_v1",
    "io.macula/whiteboard-commons/whiteboard/shape_removed_v1"
  ]

  def topics, do: @topics

  @impl true
  def init(_args), do: {:ok, nil}

  @impl true
  def handle_event(topic, payload, _meta, state) when is_map(payload) do
    if topic in @topics do
      dispatch(event_type(topic), normalize(payload))
    end

    {:noreply, state}
  end

  def handle_event(_topic, _payload, _meta, state), do: {:noreply, state}

  defp dispatch("shape_removed_v1", fact) do
    board_id = field(:board_id, fact)
    shape_id = field(:shape_id, fact)

    Store.remove_shape(board_id, shape_id)
    broadcast(board_id, {:shape_removed, shape_id})
  end

  defp dispatch("shape_amended_v1", fact) do
    board_id = field(:board_id, fact)
    shape_id = field(:shape_id, fact)
    points = field(:points, fact)

    Store.move_shape(board_id, shape_id, points)
    broadcast(board_id, {:shape_moved, %{shape_id: shape_id, points: points}})
  end

  # Guards against a peer's own catchup-replay restart re-publishing its
  # full local history to this topic -- same reasoning as
  # ShapeLifecycleToBoardShapes' own new_shape? guard.
  defp dispatch("shape_initiated_v1", fact) do
    board_id = field(:board_id, fact)

    shape = %{
      kind: field(:kind, fact),
      shape_id: field(:shape_id, fact),
      points: field(:points, fact),
      color: field(:color, fact),
      width: field(:width, fact),
      text: field(:text, fact)
    }

    if Store.new_shape?(shape.shape_id) do
      :ets.insert(Store.board_shapes_table(), {board_id, shape})
      broadcast(board_id, {:shape_placed, shape})
    end
  end

  defp broadcast(board_id, message),
    do: Phoenix.PubSub.broadcast(HecateWhiteboardWeb.PubSub, "board:" <> board_id, message)

  defp event_type(topic), do: topic |> String.split("/") |> List.last()

  # Same atom-vs-{text, Bin} tolerance as every other mesh subscriber
  # here -- see reference_macula_rpc_stream_args_atom_keys for why both
  # shapes are possible depending on what this VM already had loaded.
  defp field(key, map) when is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp normalize({:text, b}) when is_binary(b), do: b
  defp normalize(:undefined), do: nil
  defp normalize(m) when is_map(m), do: Map.new(m, fn {k, v} -> {normalize(k), normalize(v)} end)
  defp normalize(l) when is_list(l), do: Enum.map(l, &normalize/1)
  defp normalize(v), do: v
end
