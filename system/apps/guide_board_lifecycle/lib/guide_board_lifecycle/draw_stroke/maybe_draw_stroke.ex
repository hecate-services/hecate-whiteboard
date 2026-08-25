defmodule GuideBoardLifecycle.DrawStroke.MaybeDrawStroke do
  # Handler for draw_stroke_v1 -- mirrors MaybeInitiateBoard's shape.
  alias GuideBoardLifecycle.BoardAggregate
  alias GuideBoardLifecycle.DrawStroke.DrawStrokeV1
  alias GuideBoardLifecycle.DrawStroke.StrokeDrawnV1

  def handle_from_map(payload) do
    case DrawStrokeV1.from_map(payload) do
      {:ok, cmd} -> handle(cmd)
      {:error, _} = error -> error
    end
  end

  def handle(%DrawStrokeV1{} = cmd) do
    event = StrokeDrawnV1.from_command(cmd)
    {:ok, [StrokeDrawnV1.to_map(event)]}
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
end
