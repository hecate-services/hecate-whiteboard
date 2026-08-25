defmodule ProjectBoards.BoardMeshSubscriber do
  # :macula_subscriber callback for stroke_drawn_v1 facts published by
  # any peer hosting the same board_id (see GuideBoardLifecycle's
  # StrokeDrawnV1ToMesh, the other half of this pair -- same topic
  # string, must match).
  #
  # Facts arrive as READ-ONLY: this writes straight into the ETS read
  # model and broadcasts locally exactly like the local
  # StrokeDrawnV1ToBoardShapes projection does, but it never dispatches
  # a command through this host's own aggregate. That is what keeps
  # replication loop-free -- a remote stroke never re-enters the local
  # evoq event log, so it can never trigger the mesh emitter again. The
  # trade: this host's own event-sourced history holds only strokes it
  # originated itself; strokes replicated from peers live only in the
  # read model. Fine for basic replication; a real merge/log design is
  # a later phase, not this one.
  @behaviour :macula_subscriber

  @topic "io.macula/whiteboard-commons/whiteboard/stroke_drawn_v1"

  def topic, do: @topic

  @impl true
  def init(_args), do: {:ok, nil}

  @impl true
  def handle_event(@topic, payload, _meta, state) when is_map(payload) do
    fact = normalize(payload)
    board_id = fact["board_id"]

    stroke = %{
      stroke_id: fact["stroke_id"],
      points: fact["points"],
      color: fact["color"],
      width: fact["width"]
    }

    :ets.insert(ProjectBoards.Store.board_shapes_table(), {board_id, stroke})

    Phoenix.PubSub.broadcast(
      HecateWhiteboardWeb.PubSub,
      "board:" <> board_id,
      {:stroke_drawn, stroke}
    )

    {:noreply, state}
  end

  def handle_event(_topic, _payload, _meta, state), do: {:noreply, state}

  # Pubsub payloads decode with CBOR text-strings tagged {:text, bin} at
  # any depth, not plain binaries -- see
  # reference_hecate_om_service_charlist_paths's sibling gotcha,
  # reference_macula_rpc_stream_args_atom_keys's pubsub cousin, and
  # macula-realm's own Tube.Cbor.normalize/1 (same fix, independently
  # confirmed necessary here).
  defp normalize({:text, b}) when is_binary(b), do: b
  defp normalize(:undefined), do: nil
  defp normalize(m) when is_map(m), do: Map.new(m, fn {k, v} -> {normalize(k), normalize(v)} end)
  defp normalize(l) when is_list(l), do: Enum.map(l, &normalize/1)
  defp normalize(v), do: v
end
