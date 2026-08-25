defmodule GuideBoardLifecycle.ArchiveBoard.MaybeArchiveBoard do
  # Handler for archive_board_v1 -- mirrors MaybeInitiateBoard's shape.
  alias GuideBoardLifecycle.ArchiveBoard.ArchiveBoardV1
  alias GuideBoardLifecycle.ArchiveBoard.BoardArchivedV1
  alias GuideBoardLifecycle.BoardAggregate

  def handle_from_map(payload) do
    case ArchiveBoardV1.from_map(payload) do
      {:ok, cmd} -> handle(cmd)
      {:error, _} = error -> error
    end
  end

  def handle(%ArchiveBoardV1{} = cmd) do
    event = BoardArchivedV1.from_command(cmd)
    {:ok, [BoardArchivedV1.to_map(event)]}
  end

  def dispatch(%{board_id: board_id} = params) do
    case ArchiveBoardV1.new(params) do
      {:ok, cmd} ->
        evoq_cmd =
          :evoq_command.new(
            :archive_board,
            BoardAggregate,
            BoardAggregate.stream_id(board_id),
            ArchiveBoardV1.to_map(cmd)
          )

        :evoq_router.dispatch(evoq_cmd)

      {:error, _} = error ->
        error
    end
  end
end
