defmodule ProjectBoards.BoardLifecycleMeshSubscriber do
  # :macula_subscriber callback for the five board-lifecycle facts
  # published by any peer (see GuideBoardLifecycle.BoardLifecycleV1ToMesh,
  # the other half of this pair -- five topic strings, must match).
  #
  # Deliberately does NOT touch the `boards` ETS table or
  # ProjectBoards.Store -- this is the picker's "on other nodes" section
  # talking about OTHER hosts' boards, not a local read model. It only
  # re-broadcasts locally so HecateWhiteboardWeb.BoardsLive can update
  # live instead of only ever reflecting whatever its one-shot
  # ListBoardsOverMesh query saw at page load. That query stays -- it's
  # still the only way to get the initial baseline, since mesh pubsub
  # never replays for a subscriber that wasn't listening yet; this is
  # push-on-top-of-pull, not a replacement.
  @behaviour :macula_subscriber

  @topics [
    "io.macula/whiteboard-commons/whiteboard/board_initiated_v1",
    "io.macula/whiteboard-commons/whiteboard/board_hosted_v1",
    "io.macula/whiteboard-commons/whiteboard/board_archived_v1",
    "io.macula/whiteboard-commons/whiteboard/board_unarchived_v1",
    "io.macula/whiteboard-commons/whiteboard/board_renamed_v1"
  ]

  def topics, do: @topics

  @impl true
  def init(_args), do: {:ok, nil}

  @impl true
  def handle_event(topic, payload, _meta, state) when is_map(payload) do
    if topic in @topics do
      raw = normalize(payload)

      # Built explicitly, atom-keyed, rather than re-broadcasting `raw`
      # as-is -- normalize/1 only unwraps {:text, _} VALUES, it leaves
      # {:text, _}-tagged KEYS as plain strings (mirrors
      # ShapeLifecycleMeshSubscriber's own shape-map construction, same
      # reason: a consumer that always does fact.board_id/fact[:title]
      # would silently get nil half the time otherwise).
      fact = %{
        board_id: field(:board_id, raw),
        title: field(:title, raw),
        owner: field(:owner, raw),
        host: field(:host, raw)
      }

      Phoenix.PubSub.broadcast(
        HecateWhiteboardWeb.PubSub,
        "boards:remote",
        {:remote_board_event, event_type(topic), fact}
      )
    end

    {:noreply, state}
  end

  def handle_event(_topic, _payload, _meta, state), do: {:noreply, state}

  defp event_type(topic), do: topic |> String.split("/") |> List.last()

  defp field(key, map) when is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  # Same atom-vs-{text, Bin} tolerance as every other mesh subscriber
  # here (ShapeLifecycleMeshSubscriber) -- see
  # reference_macula_rpc_stream_args_atom_keys for why both shapes are
  # possible depending on what this VM already had loaded.
  defp normalize({:text, b}) when is_binary(b), do: b
  defp normalize(:undefined), do: nil
  defp normalize(m) when is_map(m), do: Map.new(m, fn {k, v} -> {normalize(k), normalize(v)} end)
  defp normalize(l) when is_list(l), do: Enum.map(l, &normalize/1)
  defp normalize(v), do: v
end
