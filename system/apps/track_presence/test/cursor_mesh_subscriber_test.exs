defmodule TrackPresence.CursorMeshSubscriberTest do
  # Same atom-vs-{text,_} payload shapes ProjectBoards.BoardMeshSubscriberTest
  # regression-tests -- see that file's own header for why both are real.
  use ExUnit.Case, async: false

  alias TrackPresence.CursorMeshSubscriber
  alias TrackPresence.Roster

  @topic CursorMeshSubscriber.topic()
  @board "board-cursormesh-test"

  setup do
    :ets.delete_all_objects(Roster.cursors_table())
    :ok
  end

  test "absorbs an atom-keyed payload into the local roster" do
    payload = %{board_id: @board, peer_id: "remote-1", x: 5, y: 6, color: "c", label: "l"}

    assert {:noreply, nil} = CursorMeshSubscriber.handle_event(@topic, payload, %{}, nil)

    assert [%{peer_id: "remote-1", x: 5, y: 6}] = Roster.list_for_board(@board)
  end

  test "absorbs a {:text, _}-tagged payload into the local roster" do
    payload = %{
      {:text, "board_id"} => @board,
      {:text, "peer_id"} => "remote-2",
      {:text, "x"} => 7,
      {:text, "y"} => 8,
      {:text, "color"} => {:text, "c"},
      {:text, "label"} => {:text, "l"}
    }

    assert {:noreply, nil} = CursorMeshSubscriber.handle_event(@topic, payload, %{}, nil)

    assert [%{peer_id: "remote-2", x: 7, y: 8}] = Roster.list_for_board(@board)
  end

  test "ignores a payload for a different topic" do
    assert {:noreply, nil} =
             CursorMeshSubscriber.handle_event("some.other.topic", %{board_id: @board}, %{}, nil)

    assert Roster.list_for_board(@board) == []
  end
end
