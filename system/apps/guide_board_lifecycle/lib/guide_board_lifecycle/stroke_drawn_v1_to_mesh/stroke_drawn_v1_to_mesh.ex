defmodule GuideBoardLifecycle.StrokeDrawnV1ToMesh.StrokeDrawnV1ToMesh do
  # Process manager: republishes every LOCALLY-originated stroke_drawn_v1
  # as a mesh fact, so a peer hosting the same board_id can replicate it.
  # Only ever fires for strokes that went through THIS host's own
  # aggregate/evoq dispatch -- a stroke arriving over mesh from a peer
  # (see ProjectBoards.BoardMeshSubscriber) is written straight to the
  # ETS read model, bypassing the aggregate entirely, so it never reaches
  # this handler and never gets re-published. That asymmetry is what
  # keeps this loop-free without needing an origin-tag on the fact.
  #
  # Topic naming and "no id in the topic" both follow this workspace's
  # own convention (see macula-io/CLAUDE.md's "Massive Scale Topic
  # Design" -- board_id lives in the payload, not baked into the topic
  # string), mirroring hecate-tube's channel_announcement.erl shape.
  #
  # evoq's own catchup replay re-delivers a host's FULL local history to
  # every registered handler on every boot, so this handler DOES
  # re-publish every historical stroke to mesh on every restart -- that
  # part is unavoidable and expected. What USED to be a real gap (a peer
  # receiving those redundant publishes had no way to tell "genuinely
  # new" from "already seen", so it accumulated duplicates and an
  # inflated stroke count) is fixed as of 2026-08-25:
  # ProjectBoards.Store.new_stroke?/1 gives the receiving side
  # (BoardMeshSubscriber) an atomic stroke_id-keyed dedup gate, so a
  # redundant publish from here is now a harmless no-op on arrival.
  @behaviour :evoq_event_handler

  @topic "io.macula/whiteboard-commons/whiteboard/stroke_drawn_v1"

  @impl true
  def interested_in, do: ["stroke_drawn_v1"]

  @impl true
  def init(_config), do: {:ok, %{}}

  @impl true
  def handle_event("stroke_drawn_v1", event, _metadata, state) do
    data = field(:data, event)

    fact = %{
      board_id: field(:board_id, data),
      stroke_id: field(:stroke_id, data),
      points: field(:points, data),
      color: field(:color, data),
      width: field(:width, data),
      drawn_at: field(:drawn_at, data)
    }

    publish(fact)
    {:ok, state}
  end

  defp publish(fact) do
    require Logger

    case :hecate_om.mesh_handles() do
      {:ok, pool, realm} ->
        result =
          :macula_publisher.start_link(
            GuideBoardLifecycle.MeshPublisher,
            pool,
            realm,
            @topic,
            fact,
            []
          )

        Logger.info(
          "[StrokeDrawnV1ToMesh] publish #{inspect(fact[:stroke_id])}: #{inspect(result)}"
        )

        :ok

      other ->
        Logger.warning("[StrokeDrawnV1ToMesh] mesh_handles: #{inspect(other)}, dropping publish")
        :ok
    end
  end

  defp field(key, map) when is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end
end
