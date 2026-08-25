defmodule GuideBoardLifecycle.MoveShape.MaybeMoveShape do
  # Handler for move_shape_v1 -- mirrors MaybePlaceSticky's shape.
  alias GuideBoardLifecycle.BoardAggregate
  alias GuideBoardLifecycle.MoveShape.MoveShapeV1
  alias GuideBoardLifecycle.MoveShape.ShapeMovedV1
  alias GuideBoardLifecycle.ShapeMutation.AnswerShapeMutationRequests

  require Logger

  def handle_from_map(payload) do
    case MoveShapeV1.from_map(payload) do
      {:ok, cmd} -> handle(cmd)
      {:error, _} = error -> error
    end
  end

  def handle(%MoveShapeV1{} = cmd) do
    event = ShapeMovedV1.from_command(cmd)
    {:ok, [ShapeMovedV1.to_map(event)]}
  end

  def dispatch(%{board_id: board_id} = params) do
    case MoveShapeV1.new(params) do
      {:ok, cmd} ->
        evoq_cmd =
          :evoq_command.new(
            :move_shape,
            BoardAggregate,
            BoardAggregate.stream_id(board_id),
            MoveShapeV1.to_map(cmd)
          )

        :evoq_router.dispatch(evoq_cmd)

      {:error, _} = error ->
        error
    end
  end

  def relay(%{board_id: board_id} = params) do
    case :hecate_om.mesh_handles() do
      {:ok, pool, realm} ->
        payload = Map.put(params, :command_type, "move_shape")

        result =
          :macula_publisher.start_link(
            GuideBoardLifecycle.MeshPublisher,
            pool,
            realm,
            AnswerShapeMutationRequests.topic(),
            payload,
            []
          )

        Logger.info("[MaybeMoveShape] relay #{board_id}: #{inspect(result)}")
        :ok

      other ->
        Logger.warning("[MaybeMoveShape] mesh_handles: #{inspect(other)}, dropping relay")
        {:error, :mesh_unavailable}
    end
  end
end
