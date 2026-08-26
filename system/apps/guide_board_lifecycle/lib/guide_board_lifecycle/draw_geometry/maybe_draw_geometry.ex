defmodule GuideBoardLifecycle.DrawGeometry.MaybeDrawGeometry do
  # Handler for draw_geometry_v1 -- mirrors MaybePlaceSticky's shape,
  # sharing the same relay-request topic (AnswerShapeMutationRequests) --
  # a basic shape is a sibling of "place a sticky"/"place a text label",
  # not a separate feature like draw_stroke vs rename_board.
  alias GuideBoardLifecycle.BoardAggregate
  alias GuideBoardLifecycle.DrawGeometry.DrawGeometryV1
  alias GuideBoardLifecycle.ShapeLifecycle.ShapeInitiatedV1
  alias GuideBoardLifecycle.ShapeMutation.AnswerShapeMutationRequests

  require Logger

  def handle_from_map(payload) do
    case DrawGeometryV1.from_map(payload) do
      {:ok, cmd} -> handle(cmd)
      {:error, _} = error -> error
    end
  end

  def handle(%DrawGeometryV1{} = cmd) do
    event =
      ShapeInitiatedV1.new(%{
        board_id: DrawGeometryV1.board_id(cmd),
        shape_id: DrawGeometryV1.shape_id(cmd),
        kind: DrawGeometryV1.kind(cmd),
        points: DrawGeometryV1.points(cmd),
        color: DrawGeometryV1.color(cmd),
        from_shape_id: DrawGeometryV1.from_shape_id(cmd),
        to_shape_id: DrawGeometryV1.to_shape_id(cmd)
      })

    {:ok, [ShapeInitiatedV1.to_map(event)]}
  end

  def dispatch(%{board_id: board_id} = params) do
    case DrawGeometryV1.new(params) do
      {:ok, cmd} ->
        evoq_cmd =
          :evoq_command.new(
            :draw_geometry,
            BoardAggregate,
            BoardAggregate.stream_id(board_id),
            DrawGeometryV1.to_map(cmd)
          )

        :evoq_router.dispatch(evoq_cmd)

      {:error, _} = error ->
        error
    end
  end

  def relay(%{board_id: board_id} = params) do
    case :hecate_om.mesh_handles() do
      {:ok, pool, realm} ->
        payload = Map.put(params, :command_type, "draw_geometry")

        result =
          :macula_publisher.start_link(
            GuideBoardLifecycle.MeshPublisher,
            pool,
            realm,
            AnswerShapeMutationRequests.topic(),
            payload,
            []
          )

        Logger.info("[MaybeDrawGeometry] relay #{board_id}: #{inspect(result)}")
        :ok

      other ->
        Logger.warning("[MaybeDrawGeometry] mesh_handles: #{inspect(other)}, dropping relay")
        {:error, :mesh_unavailable}
    end
  end
end
