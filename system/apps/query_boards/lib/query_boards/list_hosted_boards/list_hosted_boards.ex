defmodule QueryBoards.ListHostedBoards.ListHostedBoards do
  # Reads project_boards' `boards` ETS table directly, same as
  # GetBoardSnapshotById -- no aggregate reads, read model only.
  #
  # Deliberately scoped to boards THIS node hosts, not every board_id
  # this node happens to know about. A joined-but-not-hosted board also
  # gets a `boards` row (GetBoardSnapshotByIdOverMesh.materialize/1),
  # but listing those here would surface a board picked up once during a
  # single join and never refreshed since -- board discovery beyond "you
  # already have the id" is still an open design question (see the plan
  # doc's "Deferred" section), this picker isn't the place to half-solve
  # it. A board someone else hosts is still reachable directly at
  # /board/:board_id if you have the id.
  alias GuideBoardLifecycle.BoardStatus
  alias ProjectBoards.Store

  def call do
    Store.boards_table()
    # board_id is the ETS key here, not a field on the stored row (see
    # BoardLifecycleToBoards's own row shape) -- GetBoardSnapshotById
    # merges it back in the same way when it reads a single row.
    |> :ets.tab2list()
    |> Enum.map(fn {board_id, board} -> Map.put(board, :board_id, board_id) end)
    |> Enum.filter(&hosted_here?/1)
    |> Enum.map(&with_stroke_count/1)
    |> Enum.sort_by(& &1.title)
  end

  defp hosted_here?(%{status: status}) do
    :evoq_bit_flags.has(status, BoardStatus.hosted()) and
      not :evoq_bit_flags.has(status, BoardStatus.archived())
  end

  defp with_stroke_count(board) do
    stroke_count = :ets.lookup(Store.board_shapes_table(), board.board_id) |> length()
    Map.put(board, :stroke_count, stroke_count)
  end
end
