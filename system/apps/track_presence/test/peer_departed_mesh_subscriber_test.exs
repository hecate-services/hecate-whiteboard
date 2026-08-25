defmodule TrackPresence.PeerDepartedMeshSubscriberTest do
  use ExUnit.Case, async: false

  alias TrackPresence.PeerDepartedMeshSubscriber
  alias TrackPresence.Roster

  @topic PeerDepartedMeshSubscriber.topic()
  @board "board-departed-test"

  setup do
    :ets.delete_all_objects(Roster.cursors_table())
    :ok
  end

  test "removes the departed peer's cursor from the local roster" do
    Roster.touch(%{board_id: @board, peer_id: "p1", x: 1, y: 1, color: "c", label: "l"})
    assert [%{peer_id: "p1"}] = Roster.list_for_board(@board)

    payload = %{board_id: @board, peer_id: "p1", departed_at: 123}
    assert {:noreply, nil} = PeerDepartedMeshSubscriber.handle_event(@topic, payload, %{}, nil)

    assert Roster.list_for_board(@board) == []
  end

  test "a departure for a peer never seen locally is a harmless no-op" do
    payload = %{board_id: @board, peer_id: "ghost", departed_at: 123}
    assert {:noreply, nil} = PeerDepartedMeshSubscriber.handle_event(@topic, payload, %{}, nil)
    assert Roster.list_for_board(@board) == []
  end
end
