defmodule GuideBoardLifecycle.ShapeLifecycle.ShapeLifecycleV1ToMesh do
  # Republishes every LOCALLY-originated shape_initiated_v1/
  # shape_amended_v1/shape_removed_v1 as a mesh fact -- the CMD-side half
  # of shape replication (ProjectBoards.ShapeLifecycleMeshSubscriber is
  # the other half, same three topic strings, must match). Replaces
  # StrokeDrawnV1ToMesh (its own dedicated topic) and ShapeMutatedV1ToMesh
  # (one shared topic for sticky/text/move/remove/geometry) -- now that
  # shape creation is ONE event type instead of four, the same
  # shared-vs-separate-topic question BoardLifecycleV1ToMesh already
  # settled applies here too.
  #
  # One topic PER event type, not one shared topic: "a shape was
  # created", "an existing shape changed", and "a shape was removed" are
  # three distinct kinds of news, not variations of one action -- a
  # future consumer that only cares about removals shouldn't have to
  # filter the other two out. This is a DIFFERENT call than
  # ShapeMutatedV1ToMesh's old shared topic, on purpose: that shared
  # topic was for five events that were all genuine siblings of one
  # concern ("what's drawn on this board changed"); initiated/amended/
  # removed are lifecycle STAGES, not siblings, same distinction that
  # decided BoardLifecycleV1ToMesh's own design.
  @behaviour :evoq_event_handler

  @topics %{
    "shape_initiated_v1" => "io.macula/whiteboard-commons/whiteboard/shape_initiated_v1",
    "shape_amended_v1" => "io.macula/whiteboard-commons/whiteboard/shape_amended_v1",
    "shape_removed_v1" => "io.macula/whiteboard-commons/whiteboard/shape_removed_v1"
  }

  def topic(event_type), do: Map.fetch!(@topics, event_type)
  def topics, do: @topics

  @impl true
  def interested_in, do: Map.keys(@topics)

  @impl true
  def init(_config), do: {:ok, %{}}

  @impl true
  def handle_event(event_type, event, _metadata, state) do
    data = field(:data, event)

    fact = %{
      board_id: field(:board_id, data),
      shape_id: field(:shape_id, data),
      kind: field(:kind, data),
      points: field(:points, data),
      color: field(:color, data),
      width: field(:width, data),
      text: field(:text, data),
      from_shape_id: field(:from_shape_id, data),
      to_shape_id: field(:to_shape_id, data)
    }

    publish(event_type, fact)
    {:ok, state}
  end

  defp publish(event_type, fact) do
    require Logger

    case :hecate_om.mesh_handles() do
      {:ok, pool, realm} ->
        result =
          :macula_publisher.start_link(
            GuideBoardLifecycle.MeshPublisher,
            pool,
            realm,
            topic(event_type),
            fact,
            []
          )

        Logger.info(
          "[ShapeLifecycleV1ToMesh] publish #{event_type} #{fact.shape_id}: #{inspect(result)}"
        )

        :ok

      other ->
        Logger.warning(
          "[ShapeLifecycleV1ToMesh] mesh_handles: #{inspect(other)}, dropping publish"
        )

        :ok
    end
  end

  defp field(key, map) when is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end
end
