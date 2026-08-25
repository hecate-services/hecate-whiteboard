defmodule GuideBoardLifecycle.DrawStroke.MaybeDrawStroke do
  # Handler for draw_stroke_v1 -- mirrors MaybeInitiateBoard's shape.
  alias GuideBoardLifecycle.BoardAggregate
  alias GuideBoardLifecycle.DrawStroke.AnswerDrawStrokeRequests
  alias GuideBoardLifecycle.DrawStroke.DrawStrokeV1
  alias GuideBoardLifecycle.ShapeLifecycle.ShapeInitiatedV1

  require Logger

  def handle_from_map(payload) do
    case DrawStrokeV1.from_map(payload) do
      {:ok, cmd} -> handle(cmd)
      {:error, _} = error -> error
    end
  end

  def handle(%DrawStrokeV1{} = cmd) do
    event =
      ShapeInitiatedV1.new(%{
        board_id: DrawStrokeV1.board_id(cmd),
        shape_id: DrawStrokeV1.stroke_id(cmd),
        kind: "stroke",
        points: DrawStrokeV1.points(cmd),
        color: DrawStrokeV1.color(cmd),
        width: DrawStrokeV1.width(cmd)
      })

    {:ok, [ShapeInitiatedV1.to_map(event)]}
  end

  def dispatch(%{board_id: board_id} = params) do
    case DrawStrokeV1.new(params) do
      {:ok, cmd} ->
        evoq_cmd =
          :evoq_command.new(
            :draw_stroke,
            BoardAggregate,
            BoardAggregate.stream_id(board_id),
            DrawStrokeV1.to_map(cmd)
          )

        :evoq_router.dispatch(evoq_cmd)

      {:error, _} = error ->
        error
    end
  end

  # For a joining (non-hosting) peer: publish the raw draw params instead
  # of dispatching locally -- see AnswerDrawStrokeRequests for the other
  # half. stroke_id is deliberately NOT minted here; whichever node is
  # actually hosting mints it the normal way inside its own dispatch/1
  # call, exactly as if that host's own user had drawn the stroke.
  def relay(%{board_id: board_id} = params) do
    case :hecate_om.mesh_handles() do
      {:ok, pool, realm} ->
        result =
          :macula_publisher.start_link(
            GuideBoardLifecycle.MeshPublisher,
            pool,
            realm,
            AnswerDrawStrokeRequests.topic(),
            params,
            []
          )

        Logger.info("[MaybeDrawStroke] relay #{board_id}: #{inspect(result)}")
        :ok

      other ->
        Logger.warning("[MaybeDrawStroke] mesh_handles: #{inspect(other)}, dropping relay")
        {:error, :mesh_unavailable}
    end
  end
end
