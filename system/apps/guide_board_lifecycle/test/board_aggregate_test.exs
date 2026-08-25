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

  # This one is load-bearing for the write-relay (AnswerDrawStrokeRequests):
  # a relayed stroke is dispatched identically on every node, and it's
  # exactly this rejection that makes every node except the real host a
  # safe no-op instead of a split-brain write.
  test "draw_stroke rejects a board that isn't hosted here" do
    {:ok, state} = BoardAggregate.init("board-test")

    {:ok, [initiated]} =
      BoardAggregate.execute(state, %{
        command_type: :initiate_board,
        board_id: "board-test",
        owner: "raf",
        title: "t"
      })

    state = BoardAggregate.apply(state, initiated)

    assert {:error, :not_hosted} =
             BoardAggregate.execute(state, %{
               command_type: :draw_stroke,
               board_id: "board-test",
               stroke_id: "s1",
               points: [%{x: 1, y: 1}],
               color: "#f2efe6",
               width: 3
             })
  end

  test "draw_stroke rejects a board that was never initiated at all" do
    {:ok, state} = BoardAggregate.init("board-test")

    assert {:error, :not_hosted} =
             BoardAggregate.execute(state, %{
               command_type: :draw_stroke,
               board_id: "board-test",
               stroke_id: "s1",
               points: [%{x: 1, y: 1}],
               color: "#f2efe6",
               width: 3
             })
  end

  test "draw_stroke succeeds once a board is hosted" do
    {:ok, state} = BoardAggregate.init("board-test")

    {:ok, [initiated]} =
      BoardAggregate.execute(state, %{
        command_type: :initiate_board,
        board_id: "board-test",
        owner: "raf",
        title: "t"
      })

    state = BoardAggregate.apply(state, initiated)

    {:ok, [hosted]} =
      BoardAggregate.execute(state, %{command_type: :host_board, board_id: "board-test"})

    state = BoardAggregate.apply(state, hosted)

    assert {:ok, [drawn]} =
             BoardAggregate.execute(state, %{
               command_type: :draw_stroke,
               board_id: "board-test",
               stroke_id: "s1",
               points: [%{x: 1, y: 1}],
               color: "#f2efe6",
               width: 3
             })

    assert drawn.event_type == "stroke_drawn_v1"
  end

  test "unknown command is rejected" do
    {:ok, state} = BoardAggregate.init("board-test")
    assert {:error, :unknown_command} = BoardAggregate.execute(state, %{command_type: :nonsense})
  end

  # Load-bearing for AnswerLeaveBoardRequests the same way draw_stroke's
  # own :not_hosted rejection is load-bearing for AnswerDrawStrokeRequests
  # -- this is what makes every node except the real host a safe no-op.
  test "leave_board rejects a board that isn't hosted here" do
    {:ok, state} = BoardAggregate.init("board-test")

    {:ok, [initiated]} =
      BoardAggregate.execute(state, %{
        command_type: :initiate_board,
        board_id: "board-test",
        owner: "raf",
        title: "t"
      })

    state = BoardAggregate.apply(state, initiated)

    assert {:error, :not_hosted} =
             BoardAggregate.execute(state, %{
               command_type: :leave_board,
               board_id: "board-test",
               peer_id: "peer-1"
             })
  end

  test "leave_board succeeds once a board is hosted" do
    {:ok, state} = BoardAggregate.init("board-test")

    {:ok, [initiated]} =
      BoardAggregate.execute(state, %{
        command_type: :initiate_board,
        board_id: "board-test",
        owner: "raf",
        title: "t"
      })

    state = BoardAggregate.apply(state, initiated)

    {:ok, [hosted]} =
      BoardAggregate.execute(state, %{command_type: :host_board, board_id: "board-test"})

    state = BoardAggregate.apply(state, hosted)

    assert {:ok, [departed]} =
             BoardAggregate.execute(state, %{
               command_type: :leave_board,
               board_id: "board-test",
               peer_id: "peer-1"
             })

    assert departed.event_type == "peer_departed_v1"
  end

  # Deliberately different from rename_board/draw_stroke: leaving doesn't
  # mutate board content, so it stays valid even after archive_board --
  # see BoardAggregate's own comment on why this desk has no archived
  # guard.
  test "leave_board succeeds on an archived board" do
    {:ok, state} = BoardAggregate.init("board-test")

    {:ok, [initiated]} =
      BoardAggregate.execute(state, %{
        command_type: :initiate_board,
        board_id: "board-test",
        owner: "raf",
        title: "t"
      })

    state = BoardAggregate.apply(state, initiated)

    {:ok, [hosted]} =
      BoardAggregate.execute(state, %{command_type: :host_board, board_id: "board-test"})

    state = BoardAggregate.apply(state, hosted)

    {:ok, [archived]} =
      BoardAggregate.execute(state, %{command_type: :archive_board, board_id: "board-test"})

    state = BoardAggregate.apply(state, archived)

    assert {:ok, [departed]} =
             BoardAggregate.execute(state, %{
               command_type: :leave_board,
               board_id: "board-test",
               peer_id: "peer-1"
             })

    assert departed.event_type == "peer_departed_v1"
  end

  # Load-bearing for AnswerShapeMutationRequests the same way draw_stroke's
  # own :not_hosted rejection is load-bearing for AnswerDrawStrokeRequests.
  test "place_sticky rejects a board that isn't hosted here" do
    {:ok, state} = BoardAggregate.init("board-test")

    {:ok, [initiated]} =
      BoardAggregate.execute(state, %{
        command_type: :initiate_board,
        board_id: "board-test",
        owner: "raf",
        title: "t"
      })

    state = BoardAggregate.apply(state, initiated)

    assert {:error, :not_hosted} =
             BoardAggregate.execute(state, %{
               command_type: :place_sticky,
               board_id: "board-test",
               shape_id: "s1",
               x: 1,
               y: 1,
               color: "#f2994a",
               text: "hello"
             })
  end

  test "place_sticky succeeds once a board is hosted" do
    {:ok, state} = BoardAggregate.init("board-test")

    {:ok, [initiated]} =
      BoardAggregate.execute(state, %{
        command_type: :initiate_board,
        board_id: "board-test",
        owner: "raf",
        title: "t"
      })

    state = BoardAggregate.apply(state, initiated)

    {:ok, [hosted]} =
      BoardAggregate.execute(state, %{command_type: :host_board, board_id: "board-test"})

    state = BoardAggregate.apply(state, hosted)

    assert {:ok, [placed]} =
             BoardAggregate.execute(state, %{
               command_type: :place_sticky,
               board_id: "board-test",
               shape_id: "s1",
               x: 1,
               y: 1,
               color: "#f2994a",
               text: "hello"
             })

    assert placed.event_type == "sticky_placed_v1"
  end

  test "place_text rejects a board that isn't hosted here" do
    {:ok, state} = BoardAggregate.init("board-test")

    {:ok, [initiated]} =
      BoardAggregate.execute(state, %{
        command_type: :initiate_board,
        board_id: "board-test",
        owner: "raf",
        title: "t"
      })

    state = BoardAggregate.apply(state, initiated)

    assert {:error, :not_hosted} =
             BoardAggregate.execute(state, %{
               command_type: :place_text,
               board_id: "board-test",
               shape_id: "s1",
               x: 1,
               y: 1,
               color: "#f2efe6",
               text: "hello"
             })
  end

  test "place_text succeeds once a board is hosted" do
    {:ok, state} = BoardAggregate.init("board-test")

    {:ok, [initiated]} =
      BoardAggregate.execute(state, %{
        command_type: :initiate_board,
        board_id: "board-test",
        owner: "raf",
        title: "t"
      })

    state = BoardAggregate.apply(state, initiated)

    {:ok, [hosted]} =
      BoardAggregate.execute(state, %{command_type: :host_board, board_id: "board-test"})

    state = BoardAggregate.apply(state, hosted)

    assert {:ok, [placed]} =
             BoardAggregate.execute(state, %{
               command_type: :place_text,
               board_id: "board-test",
               shape_id: "s1",
               x: 1,
               y: 1,
               color: "#f2efe6",
               text: "hello"
             })

    assert placed.event_type == "text_placed_v1"
  end

  test "move_shape rejects a board that isn't hosted here" do
    {:ok, state} = BoardAggregate.init("board-test")

    {:ok, [initiated]} =
      BoardAggregate.execute(state, %{
        command_type: :initiate_board,
        board_id: "board-test",
        owner: "raf",
        title: "t"
      })

    state = BoardAggregate.apply(state, initiated)

    assert {:error, :not_hosted} =
             BoardAggregate.execute(state, %{
               command_type: :move_shape,
               board_id: "board-test",
               shape_id: "s1",
               points: [%{x: 5, y: 5}]
             })
  end

  test "move_shape succeeds once a board is hosted" do
    {:ok, state} = BoardAggregate.init("board-test")

    {:ok, [initiated]} =
      BoardAggregate.execute(state, %{
        command_type: :initiate_board,
        board_id: "board-test",
        owner: "raf",
        title: "t"
      })

    state = BoardAggregate.apply(state, initiated)

    {:ok, [hosted]} =
      BoardAggregate.execute(state, %{command_type: :host_board, board_id: "board-test"})

    state = BoardAggregate.apply(state, hosted)

    assert {:ok, [moved]} =
             BoardAggregate.execute(state, %{
               command_type: :move_shape,
               board_id: "board-test",
               shape_id: "s1",
               points: [%{x: 5, y: 5}]
             })

    assert moved.event_type == "shape_moved_v1"
  end

  test "remove_shape rejects a board that isn't hosted here" do
    {:ok, state} = BoardAggregate.init("board-test")

    {:ok, [initiated]} =
      BoardAggregate.execute(state, %{
        command_type: :initiate_board,
        board_id: "board-test",
        owner: "raf",
        title: "t"
      })

    state = BoardAggregate.apply(state, initiated)

    assert {:error, :not_hosted} =
             BoardAggregate.execute(state, %{
               command_type: :remove_shape,
               board_id: "board-test",
               shape_id: "s1"
             })
  end

  test "remove_shape succeeds once a board is hosted" do
    {:ok, state} = BoardAggregate.init("board-test")

    {:ok, [initiated]} =
      BoardAggregate.execute(state, %{
        command_type: :initiate_board,
        board_id: "board-test",
        owner: "raf",
        title: "t"
      })

    state = BoardAggregate.apply(state, initiated)

    {:ok, [hosted]} =
      BoardAggregate.execute(state, %{command_type: :host_board, board_id: "board-test"})

    state = BoardAggregate.apply(state, hosted)

    assert {:ok, [removed]} =
             BoardAggregate.execute(state, %{
               command_type: :remove_shape,
               board_id: "board-test",
               shape_id: "s1"
             })

    assert removed.event_type == "shape_removed_v1"
  end

  test "place_sticky rejects an archived board" do
    {:ok, state} = BoardAggregate.init("board-test")

    {:ok, [initiated]} =
      BoardAggregate.execute(state, %{
        command_type: :initiate_board,
        board_id: "board-test",
        owner: "raf",
        title: "t"
      })

    state = BoardAggregate.apply(state, initiated)

    {:ok, [hosted]} =
      BoardAggregate.execute(state, %{command_type: :host_board, board_id: "board-test"})

    state = BoardAggregate.apply(state, hosted)

    {:ok, [archived]} =
      BoardAggregate.execute(state, %{command_type: :archive_board, board_id: "board-test"})

    state = BoardAggregate.apply(state, archived)

    assert {:error, :archived} =
             BoardAggregate.execute(state, %{
               command_type: :place_sticky,
               board_id: "board-test",
               shape_id: "s1",
               x: 1,
               y: 1,
               color: "#f2994a",
               text: "hello"
             })
  end

  test "draw_geometry rejects a board that isn't hosted here" do
    {:ok, state} = BoardAggregate.init("board-test")

    {:ok, [initiated]} =
      BoardAggregate.execute(state, %{
        command_type: :initiate_board,
        board_id: "board-test",
        owner: "raf",
        title: "t"
      })

    state = BoardAggregate.apply(state, initiated)

    assert {:error, :not_hosted} =
             BoardAggregate.execute(state, %{
               command_type: :draw_geometry,
               board_id: "board-test",
               shape_id: "s1",
               kind: "rectangle",
               points: [%{x: 1, y: 1}, %{x: 5, y: 5}],
               color: "#f2efe6"
             })
  end

  test "draw_geometry succeeds once a board is hosted" do
    {:ok, state} = BoardAggregate.init("board-test")

    {:ok, [initiated]} =
      BoardAggregate.execute(state, %{
        command_type: :initiate_board,
        board_id: "board-test",
        owner: "raf",
        title: "t"
      })

    state = BoardAggregate.apply(state, initiated)

    {:ok, [hosted]} =
      BoardAggregate.execute(state, %{command_type: :host_board, board_id: "board-test"})

    state = BoardAggregate.apply(state, hosted)

    assert {:ok, [drawn]} =
             BoardAggregate.execute(state, %{
               command_type: :draw_geometry,
               board_id: "board-test",
               shape_id: "s1",
               kind: "ellipse",
               points: [%{x: 1, y: 1}, %{x: 5, y: 5}],
               color: "#f2efe6"
             })

    assert drawn.event_type == "geometry_drawn_v1"
  end

  test "draw_geometry rejects an archived board" do
    {:ok, state} = BoardAggregate.init("board-test")

    {:ok, [initiated]} =
      BoardAggregate.execute(state, %{
        command_type: :initiate_board,
        board_id: "board-test",
        owner: "raf",
        title: "t"
      })

    state = BoardAggregate.apply(state, initiated)

    {:ok, [hosted]} =
      BoardAggregate.execute(state, %{command_type: :host_board, board_id: "board-test"})

    state = BoardAggregate.apply(state, hosted)

    {:ok, [archived]} =
      BoardAggregate.execute(state, %{command_type: :archive_board, board_id: "board-test"})

    state = BoardAggregate.apply(state, archived)

    assert {:error, :archived} =
             BoardAggregate.execute(state, %{
               command_type: :draw_geometry,
               board_id: "board-test",
               shape_id: "s1",
               kind: "triangle",
               points: [%{x: 1, y: 1}, %{x: 5, y: 5}],
               color: "#f2efe6"
             })
  end
end
