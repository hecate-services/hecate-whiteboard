defmodule GuideBoardLifecycle.ShapeMutation.ShapeMutatedV1ToMesh do
  # Republishes every LOCALLY-originated sticky_placed_v1/text_placed_v1/
  # shape_moved_v1/shape_removed_v1/geometry_drawn_v1 as a mesh fact, so
  # a peer hosting (or watching) the same board_id can replicate it. Mirrors
  # StrokeDrawnV1ToMesh's shape and its own loop-free reasoning: a mutation
  # arriving over mesh is written straight into the read model (see
  # ProjectBoards.ShapeMeshSubscriber), bypassing the aggregate entirely,
  # so it never reaches this handler and never gets re-published.
  #
  # ONE shared topic for all four event types (mirrors
  # AnswerShapeMutationRequests' own consolidation on the request side) --
  # the embedded event_type field is what the receiving side pattern
  # matches on to decide how to apply it.
  @behaviour :evoq_event_handler

  @topic "io.macula/whiteboard-commons/whiteboard/shape_mutated_v1"

  @impl true
  def interested_in,
    do: [
      "sticky_placed_v1",
      "text_placed_v1",
      "shape_moved_v1",
      "shape_removed_v1",
      "geometry_drawn_v1"
    ]

  @impl true
  def init(_config), do: {:ok, %{}}

  @impl true
  def handle_event(event_type, event, _metadata, state) do
    data = field(:data, event)
    fact = data |> Map.new(fn {k, v} -> {k, v} end) |> Map.put(:event_type, event_type)
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
          "[ShapeMutatedV1ToMesh] publish #{fact[:event_type]} #{inspect(fact[:shape_id])}: #{inspect(result)}"
        )

        :ok

      other ->
        Logger.warning("[ShapeMutatedV1ToMesh] mesh_handles: #{inspect(other)}, dropping publish")
        :ok
    end
  end

  defp field(key, map) when is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end
end
