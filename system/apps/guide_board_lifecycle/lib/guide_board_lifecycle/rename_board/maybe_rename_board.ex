defmodule GuideBoardLifecycle.RenameBoard.MaybeRenameBoard do
  # Handler for rename_board_v1 -- mirrors MaybeArchiveBoard's shape.
  alias GuideBoardLifecycle.BoardAggregate
  alias GuideBoardLifecycle.RenameBoard.BoardRenamedV1
  alias GuideBoardLifecycle.RenameBoard.RenameBoardV1

  def handle_from_map(payload) do
    case RenameBoardV1.from_map(payload) do
      {:ok, cmd} -> handle(cmd)
      {:error, _} = error -> error
    end
  end

  def handle(%RenameBoardV1{} = cmd) do
    event = BoardRenamedV1.from_command(cmd)
    {:ok, [BoardRenamedV1.to_map(event)]}
  end

  def dispatch(%{board_id: board_id} = params) do
    case RenameBoardV1.new(params) do
      {:ok, cmd} ->
        evoq_cmd =
          :evoq_command.new(
            :rename_board,
            BoardAggregate,
            BoardAggregate.stream_id(board_id),
            RenameBoardV1.to_map(cmd)
          )

        :evoq_router.dispatch(evoq_cmd)

      {:error, _} = error ->
        error
    end
  end
end
