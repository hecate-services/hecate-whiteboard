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
    board_id = field(:board_id, fact)
    stroke_id = field(:stroke_id, fact)

    # Guards against a peer's own catchup-replay restart re-publishing its
    # full local history to this topic -- see ProjectBoards.Store's module
    # doc. Without this, every restart on the OTHER end re-drew that
    # peer's entire history on this one.
    if ProjectBoards.Store.new_stroke?(stroke_id) do
      stroke = %{
        kind: "stroke",
        shape_id: stroke_id,
        stroke_id: stroke_id,
        points: field(:points, fact),
        color: field(:color, fact),
        width: field(:width, fact)
      }

      :ets.insert(ProjectBoards.Store.board_shapes_table(), {board_id, stroke})

      Phoenix.PubSub.broadcast(
        HecateWhiteboardWeb.PubSub,
        "board:" <> board_id,
        {:stroke_drawn, stroke}
      )
    end

    {:noreply, state}
  end

  def handle_event(_topic, _payload, _meta, state), do: {:noreply, state}

  # Field keys arrive as plain ATOMS whenever this VM already has the
  # atom loaded (which it does -- this module's own struct-free maps use
  # the same field names), same "atomize if known, else {text, Bin}"
  # mechanism reference_macula_rpc_stream_args_atom_keys documented for
  # macula's RPC/stream path -- confirmed live 2026-08-25 that macula
  # 10.1.1 does the SAME thing for plain pubsub delivery too, not just
  # RPC/streaming as that memory originally scoped it. The older,
  # narrower assumption (pubsub payloads always arrive {text, Bin}-tagged,
  # per erlang_macula_sdk_payload_keys and macula-realm's Tube.Cbor) is
  # what actually crashed here first: `fact["board_id"]` against an
  # atom-keyed map returned nil, then `"board:" <> nil` raised
  # ArgumentError deep in Phoenix.PubSub.broadcast/3. Tolerating both
  # shapes (plus the {text, Bin} case normalize/1 still handles, for
  # whichever atoms this VM does NOT already have loaded) is the correct
  # fix, not picking one.
  defp field(key, map) when is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  # Pubsub payloads can still carry CBOR text-strings tagged {:text, bin}
  # for any key/atom this VM doesn't already have loaded -- see the
  # field/2 comment above for the full picture.
  defp normalize({:text, b}) when is_binary(b), do: b
  defp normalize(:undefined), do: nil
  defp normalize(m) when is_map(m), do: Map.new(m, fn {k, v} -> {normalize(k), normalize(v)} end)
  defp normalize(l) when is_list(l), do: Enum.map(l, &normalize/1)
  defp normalize(v), do: v
end
