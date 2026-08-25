defmodule TrackPresence.RosterTest do
  use ExUnit.Case, async: false

  alias TrackPresence.Roster

  @board "board-roster-test"

  setup do
    :ets.delete_all_objects(Roster.cursors_table())
    :ok
  end

  test "touch writes the row and broadcasts locally" do
    Phoenix.PubSub.subscribe(HecateWhiteboardWeb.PubSub, "board:" <> @board)

    Roster.touch(%{
      board_id: @board,
      peer_id: "p1",
      x: 10,
      y: 20,
      color: "hsl(1, 70%, 65%)",
      label: "beam01 via de-falkenstein"
    })

    assert_receive {:cursor_settled, @board, %{peer_id: "p1", x: 10, y: 20}}

    assert [%{peer_id: "p1", x: 10, y: 20}] = Roster.list_for_board(@board)
  end

  test "remove deletes the row and broadcasts only when a row existed" do
    Roster.touch(%{board_id: @board, peer_id: "p1", x: 1, y: 1, color: "c", label: "l"})

    Phoenix.PubSub.subscribe(HecateWhiteboardWeb.PubSub, "board:" <> @board)

    Roster.remove(@board, "p1")
    assert_receive {:cursor_left, @board, "p1"}
    assert Roster.list_for_board(@board) == []

    # Removing an already-gone (or never-present) peer is a silent no-op,
    # not a second broadcast -- this is what makes a stray disconnected
    # LiveView's terminate/2 (see BoardLive's own comment) harmless.
    Roster.remove(@board, "p1")
    refute_receive {:cursor_left, @board, "p1"}
  end

  test "sweep ages out only rows older than stale_after_ms" do
    Roster.touch(%{board_id: @board, peer_id: "fresh", x: 1, y: 1, color: "c", label: "l"})
    Roster.touch(%{board_id: @board, peer_id: "stale", x: 2, y: 2, color: "c", label: "l"})

    far_future = System.system_time(:millisecond) + Roster.stale_after_ms() + 1_000
    Roster.sweep(far_future)

    # Both were older than stale_after_ms as of far_future, so both go --
    # the real distinguishing factor is each row's OWN last_seen, which
    # this test doesn't stagger. See the next assertion for that case.
    assert Roster.list_for_board(@board) == []
  end

  test "sweep spares a row touched after an earlier one" do
    # "old" backdated directly in ETS (bypassing touch/1's own
    # System.system_time capture) rather than relying on a real sleep
    # between two touch/1 calls, which a fast test can't guarantee
    # straddles a stale_after_ms boundary reliably.
    :ets.insert(
      Roster.cursors_table(),
      {{@board, "old"}, %{x: 1, y: 1, color: "c", label: "l", last_seen: 0}}
    )

    Roster.touch(%{board_id: @board, peer_id: "new", x: 2, y: 2, color: "c", label: "l"})

    Roster.sweep(Roster.stale_after_ms() + 1_000)

    assert [%{peer_id: "new"}] = Roster.list_for_board(@board)
  end
end
