defmodule QueryBoards.AnswerBoardSnapshotQueriesTest do
  use ExUnit.Case, async: false

  alias GuideBoardLifecycle.BoardStatus
  alias ProjectBoards.Store
  alias QueryBoards.AnswerBoardSnapshotQueries

  setup do
    :ets.delete_all_objects(Store.boards_table())
    :ets.delete_all_objects(Store.board_shapes_table())
    :ok
  end

  test "answers for a board this node hosts and has not archived" do
    status = :evoq_bit_flags.set(BoardStatus.initiated(), BoardStatus.hosted())
    assert AnswerBoardSnapshotQueries.authoritative_here?(%{status: status})
  end

  test "stays silent for a board this node hosts but has archived" do
    status =
      BoardStatus.initiated()
      |> :evoq_bit_flags.set(BoardStatus.hosted())
      |> :evoq_bit_flags.set(BoardStatus.archived())

    refute AnswerBoardSnapshotQueries.authoritative_here?(%{status: status})
  end

  test "stays silent for a board this node only replicates, never hosted" do
    refute AnswerBoardSnapshotQueries.authoritative_here?(%{status: BoardStatus.initiated()})
  end

  test "a query for a board this node has never seen doesn't crash" do
    payload = %{board_id: "board-neverheardofit", reply_to: "some-reply-topic"}

    assert {:noreply, nil} =
             AnswerBoardSnapshotQueries.handle_event(
               AnswerBoardSnapshotQueries.topic(),
               payload,
               %{},
               nil
             )
  end

  test "ignores a payload for a different topic" do
    assert {:noreply, nil} =
             AnswerBoardSnapshotQueries.handle_event(
               "some.other.topic",
               %{board_id: "x"},
               %{},
               nil
             )
  end
end
