defmodule QueryBoards.GetBoardSnapshotById.GetBoardSnapshotById do
  # Reads the current board + its shapes straight from project_boards'
  # ETS tables. Even though the host's own aggregate process holds
  # current status in memory, queries still go through the read model,
  # never the aggregate directly -- keeps write/read sides decoupled per
  # this workspace's stated CQRS principle.
  alias ProjectBoards.Store

  def call(board_id) do
    case :ets.lookup(Store.boards_table(), board_id) do
      [{^board_id, board}] ->
        shapes =
          :ets.lookup(Store.board_shapes_table(), board_id)
          |> Enum.map(fn {_id, stroke} -> stroke end)

        {:ok, %{board: Map.put(board, :board_id, board_id), shapes: shapes}}

      [] ->
        {:error, :not_found}
    end
  end
end
