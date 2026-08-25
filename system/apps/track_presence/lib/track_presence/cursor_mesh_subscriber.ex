defmodule TrackPresence.CursorMeshSubscriber do
  # :macula_subscriber callback for cursor_settled_v1 facts published by
  # any peer viewing the same board_id (see Roster.touch/1, the other
  # half of this pair -- same topic string, must match). Absorbs into the
  # local roster only, never re-publishes -- see Roster's own header for
  # why that keeps this loop-free.
  @behaviour :macula_subscriber

  alias TrackPresence.Roster

  @topic Roster.topic()

  def topic, do: @topic

  @impl true
  def init(_args), do: {:ok, nil}

  @impl true
  def handle_event(@topic, payload, _meta, state) when is_map(payload) do
    fact = normalize(payload)

    Roster.absorb_remote(%{
      board_id: field(:board_id, fact),
      peer_id: field(:peer_id, fact),
      x: field(:x, fact),
      y: field(:y, fact),
      color: field(:color, fact),
      label: field(:label, fact)
    })

    {:noreply, state}
  end

  def handle_event(_topic, _payload, _meta, state), do: {:noreply, state}

  # Same atom-vs-{text,_} tolerance every mesh receiver in this repo
  # needs -- see ProjectBoards.ShapeLifecycleMeshSubscriber's own comment
  # for the full story.
  defp field(key, map) when is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp normalize({:text, b}) when is_binary(b), do: b
  defp normalize(:undefined), do: nil
  defp normalize(m) when is_map(m), do: Map.new(m, fn {k, v} -> {normalize(k), normalize(v)} end)
  defp normalize(l) when is_list(l), do: Enum.map(l, &normalize/1)
  defp normalize(v), do: v
end
