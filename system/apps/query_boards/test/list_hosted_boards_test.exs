defmodule QueryBoards.ListHostedBoardsTest do
  # ETS-level tests, no live evoq dispatch -- mirrors this workspace's own
  # convention (see guide_board_lifecycle/test/board_aggregate_test.exs's
  # header) of keeping unit tests off a real reckon-db boot.
  #
  # Row shape here deliberately omits board_id from the VALUE map (only
  # the ETS key carries it) -- that's the real shape
  # BoardLifecycleToBoards stores, and the first cut of ListHostedBoards
  # got this wrong (discarded the key, then crashed with a KeyError the
  # moment a real board existed) because these tests originally put
  # board_id in the value too, matching the bug instead of catching it.
  use ExUnit.Case, async: false

  alias GuideBoardLifecycle.BoardStatus
  alias ProjectBoards.Store
  alias QueryBoards.ListHostedBoards.ListHostedBoards

  setup do
    :ets.delete_all_objects(Store.boards_table())
    :ets.delete_all_objects(Store.board_shapes_table())
    :ok
  end

  test "lists a hosted, non-archived board with its stroke count" do
    status = :evoq_bit_flags.set(BoardStatus.initiated(), BoardStatus.hosted())
    :ets.insert(Store.boards_table(), {"board-a", %{owner: "raf", title: "A", status: status}})
    :ets.insert(Store.board_shapes_table(), {"board-a", %{stroke_id: "s1"}})
    :ets.insert(Store.board_shapes_table(), {"board-a", %{stroke_id: "s2"}})

    assert [%{board_id: "board-a", title: "A", stroke_count: 2}] = ListHostedBoards.call()
  end

  test "excludes a board this node only replicates, never hosted" do
    :ets.insert(
      Store.boards_table(),
      {"board-b", %{owner: "raf", title: "B", status: BoardStatus.initiated()}}
    )

    assert ListHostedBoards.call() == []
  end

  test "excludes an archived board even though it was hosted here" do
    status =
      BoardStatus.initiated()
      |> :evoq_bit_flags.set(BoardStatus.hosted())
      |> :evoq_bit_flags.set(BoardStatus.archived())

    :ets.insert(Store.boards_table(), {"board-c", %{owner: "raf", title: "C", status: status}})

    assert ListHostedBoards.call() == []
  end

  test "sorts by title" do
    status = :evoq_bit_flags.set(BoardStatus.initiated(), BoardStatus.hosted())

    :ets.insert(
      Store.boards_table(),
      {"board-z", %{owner: "raf", title: "Zebra", status: status}}
    )

    :ets.insert(
      Store.boards_table(),
      {"board-a", %{owner: "raf", title: "Apple", status: status}}
    )

    assert [%{title: "Apple"}, %{title: "Zebra"}] = ListHostedBoards.call()
  end
end
