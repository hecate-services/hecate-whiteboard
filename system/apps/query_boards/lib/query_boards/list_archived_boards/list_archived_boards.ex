defmodule QueryBoards.ListArchivedBoards.ListArchivedBoards do
  # The archived twin of QueryBoards.ListHostedBoards -- same table, same
  # read-model-only approach, opposite half of the same "hosted AND
  # (NOT archived / archived)" filter. Kept as its OWN desk rather than an
  # option on ListHostedBoards.call/1: the two callers of the existing
  # query (AnswerBoardListQueries, answering mesh "what do you host"
  # queries from other nodes, and BoardsLive's own primary board list)
  # both genuinely want "hosted and active" ONLY -- an archived board
  # must never become mesh-discoverable again just because BoardsLive
  # also wants to list it locally for an Unarchive button. Same read
  # model, deliberately different queries for deliberately different
  # audiences.
  alias GuideBoardLifecycle.BoardStatus
  alias ProjectBoards.Store

  def call do
    Store.boards_table()
    |> :ets.tab2list()
    |> Enum.map(fn {board_id, board} -> Map.put(board, :board_id, board_id) end)
    |> Enum.filter(&archived_here?/1)
    |> Enum.map(&with_stroke_count/1)
    |> Enum.sort_by(& &1.title)
  end

  defp archived_here?(%{status: status}) do
    :evoq_bit_flags.has(status, BoardStatus.hosted()) and
      :evoq_bit_flags.has(status, BoardStatus.archived())
  end

  defp with_stroke_count(board) do
    stroke_count = :ets.lookup(Store.board_shapes_table(), board.board_id) |> length()
    Map.put(board, :stroke_count, stroke_count)
  end
end
