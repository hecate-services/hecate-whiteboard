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
  # KNOWN GAP, confirmed live 2026-08-25, not fixed here: evoq's own
  # catchup replay re-delivers a host's FULL local history to every
  # registered handler on every boot (confirmed: "[evoq] Catch-up
  # board_store: routed N events" in the logs) -- this handler has no way
  # to tell "genuinely new" from "replayed on restart", so it
  # re-publishes every historical stroke to mesh on every restart. A
  # peer that already has those strokes (from before, or from its OWN
  # catchup) ends up with duplicate ETS bag entries and an inflated
  # stroke count until its own restart cleans it up. Same root cause as
  # the "no dedup on stroke_id" simplification already noted in
  # ProjectBoards.BoardMeshSubscriber -- a stroke_id-keyed dedup on the
  # receiving side (ETS :set instead of :bag, or an explicit seen-set)
  # would fix both at once. Not done here: basic replication was the
  # goal, not exactly-once delivery.
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
