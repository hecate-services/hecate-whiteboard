defmodule GuideBoardLifecycle.UnarchiveBoard.MaybeUnarchiveBoard do
  # Handler for unarchive_board_v1 -- mirrors MaybeArchiveBoard's shape.
  alias GuideBoardLifecycle.BoardAggregate
  alias GuideBoardLifecycle.UnarchiveBoard.BoardUnarchivedV1
  alias GuideBoardLifecycle.UnarchiveBoard.UnarchiveBoardV1

  def handle_from_map(payload) do
    case UnarchiveBoardV1.from_map(payload) do
      {:ok, cmd} -> handle(cmd)
      {:error, _} = error -> error
    end
  end

  def handle(%UnarchiveBoardV1{} = cmd) do
    event = BoardUnarchivedV1.from_command(cmd)
    {:ok, [BoardUnarchivedV1.to_map(event)]}
  end

  def dispatch(%{board_id: board_id} = params) do
    case UnarchiveBoardV1.new(params) do
      {:ok, cmd} ->
        evoq_cmd =
          :evoq_command.new(
            :unarchive_board,
            BoardAggregate,
            BoardAggregate.stream_id(board_id),
            UnarchiveBoardV1.to_map(cmd)
          )

        :evoq_router.dispatch(evoq_cmd)

      {:error, _} = error ->
        error
    end
  end
end
