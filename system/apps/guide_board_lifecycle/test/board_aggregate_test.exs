defmodule GuideBoardLifecycle.BoardAggregateTest do
  # Pure unit tests: business-rule guards only, no live evoq dispatch (that
  # needs a real reckon-db boot -- see scripts/smoke_test.exs at the repo
  # root for the live-dispatch recipe). Mirrors hecate-tube's
  # channel_aggregate_tests.erl split.
  use ExUnit.Case, async: true

  alias GuideBoardLifecycle.BoardAggregate
  alias GuideBoardLifecycle.BoardState

  test "initiate_board succeeds on a fresh board" do
    {:ok, state} = BoardAggregate.init("board-test")

    assert {:ok, [event]} =
             BoardAggregate.execute(state, %{
               command_type: :initiate_board,
               board_id: "board-test",
               owner: "raf",
               title: "t"
             })

    assert event.event_type == "board_initiated_v1"
  end

  test "initiate_board rejects a board that is already initiated" do
    {:ok, state} = BoardAggregate.init("board-test")
    payload = %{command_type: :initiate_board, board_id: "board-test", owner: "raf", title: "t"}
    {:ok, [event]} = BoardAggregate.execute(state, payload)
    state = BoardAggregate.apply(state, event)

    assert {:error, :already_initiated} = BoardAggregate.execute(state, payload)
  end

  test "archive_board rejects a board that was never initiated" do
    {:ok, state} = BoardAggregate.init("board-test")

    assert {:error, :not_initiated} =
             BoardAggregate.execute(state, %{command_type: :archive_board, board_id: "board-test"})
  end

  test "archive_board rejects a board that is already archived" do
    {:ok, state} = BoardAggregate.init("board-test")

    {:ok, [initiated]} =
      BoardAggregate.execute(state, %{
        command_type: :initiate_board,
        board_id: "board-test",
        owner: "raf",
        title: "t"
      })

    state = BoardAggregate.apply(state, initiated)

    {:ok, [archived]} =
      BoardAggregate.execute(state, %{command_type: :archive_board, board_id: "board-test"})

    state = BoardAggregate.apply(state, archived)

    assert BoardState.status(state) == 3

    assert {:error, :already_archived} =
             BoardAggregate.execute(state, %{command_type: :archive_board, board_id: "board-test"})
  end

  test "rename_board succeeds on an initiated board and changes its title" do
    {:ok, state} = BoardAggregate.init("board-test")

    {:ok, [initiated]} =
      BoardAggregate.execute(state, %{
        command_type: :initiate_board,
        board_id: "board-test",
        owner: "raf",
        title: "t"
      })

    state = BoardAggregate.apply(state, initiated)

    assert {:ok, [renamed]} =
             BoardAggregate.execute(state, %{
               command_type: :rename_board,
               board_id: "board-test",
               title: "New title"
             })

    assert renamed.event_type == "board_renamed_v1"
    state = BoardAggregate.apply(state, renamed)
    assert state.title == "New title"
  end

  test "rename_board rejects a board that was never initiated" do
    {:ok, state} = BoardAggregate.init("board-test")

    assert {:error, :not_initiated} =
             BoardAggregate.execute(state, %{
               command_type: :rename_board,
               board_id: "board-test",
               title: "New title"
             })
  end

  test "rename_board rejects an archived board" do
    {:ok, state} = BoardAggregate.init("board-test")

    {:ok, [initiated]} =
      BoardAggregate.execute(state, %{
        command_type: :initiate_board,
        board_id: "board-test",
        owner: "raf",
        title: "t"
      })

    state = BoardAggregate.apply(state, initiated)

    {:ok, [archived]} =
      BoardAggregate.execute(state, %{command_type: :archive_board, board_id: "board-test"})

    state = BoardAggregate.apply(state, archived)

    assert {:error, :archived} =
             BoardAggregate.execute(state, %{
               command_type: :rename_board,
               board_id: "board-test",
               title: "New title"
             })
  end

  test "unknown command is rejected" do
    {:ok, state} = BoardAggregate.init("board-test")
    assert {:error, :unknown_command} = BoardAggregate.execute(state, %{command_type: :nonsense})
  end
end
