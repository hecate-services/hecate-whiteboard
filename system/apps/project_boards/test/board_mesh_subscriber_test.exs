defmodule ProjectBoards.BoardMeshSubscriberTest do
  # Regression test for the exact bug that crashed in production
  # 2026-08-25: a subscriber written against the "pubsub payloads are
  # always {text, Bin}-tagged" assumption got `nil` back from an
  # atom-keyed payload, then crashed on `"board:" <> nil`. Both key
  # shapes are real and must both work -- see BoardMeshSubscriber's own
  # header comment and reference_macula_rpc_stream_args_atom_keys.
  use ExUnit.Case, async: false

  alias ProjectBoards.BoardMeshSubscriber
  alias ProjectBoards.Store

  @topic BoardMeshSubscriber.topic()

  setup do
    :ets.delete_all_objects(Store.board_shapes_table())
    :ets.delete_all_objects(Store.board_shapes_seen_table())
    :ok
  end

  test "handles an atom-keyed payload (macula 10.1.1's real shape when the VM already knows the atoms)" do
    payload = %{
      board_id: "board-atomtest",
      stroke_id: "s1",
      points: [%{x: 1, y: 2}],
      color: "#f2efe6",
      width: 3
    }

    assert {:noreply, nil} = BoardMeshSubscriber.handle_event(@topic, payload, %{}, nil)

    assert [{"board-atomtest", %{stroke_id: "s1", color: "#f2efe6", width: 3}}] =
             :ets.lookup(Store.board_shapes_table(), "board-atomtest")
  end

  test "handles a {:text, _}-tagged payload (the shape for atoms this VM hasn't loaded)" do
    payload = %{
      {:text, "board_id"} => "board-texttest",
      {:text, "stroke_id"} => "s2",
      {:text, "points"} => [%{{:text, "x"} => 1, {:text, "y"} => 2}],
      {:text, "color"} => {:text, "#d89b4a"},
      {:text, "width"} => 4
    }

    assert {:noreply, nil} = BoardMeshSubscriber.handle_event(@topic, payload, %{}, nil)

    assert [{"board-texttest", %{stroke_id: "s2", color: "#d89b4a", width: 4}}] =
             :ets.lookup(Store.board_shapes_table(), "board-texttest")
  end

  test "ignores a payload for a different topic" do
    assert {:noreply, nil} =
             BoardMeshSubscriber.handle_event("some.other.topic", %{board_id: "x"}, %{}, nil)

    assert :ets.lookup(Store.board_shapes_table(), "x") == []
  end

  test "drops a redelivered stroke_id instead of storing it twice" do
    # Regression for the catchup-replay bug: a peer's restart re-publishes
    # its full local history to this topic, so the same stroke_id arrives
    # more than once. Without the dedup guard this used to re-broadcast
    # (and, if the two deliveries ever differed in shape, double-insert)
    # on every redelivery.
    payload = %{
      board_id: "board-duptest",
      stroke_id: "s3",
      points: [%{x: 1, y: 2}],
      color: "#f2efe6",
      width: 3
    }

    assert {:noreply, nil} = BoardMeshSubscriber.handle_event(@topic, payload, %{}, nil)
    assert {:noreply, nil} = BoardMeshSubscriber.handle_event(@topic, payload, %{}, nil)
    assert {:noreply, nil} = BoardMeshSubscriber.handle_event(@topic, payload, %{}, nil)

    assert [{"board-duptest", %{stroke_id: "s3"}}] =
             :ets.lookup(Store.board_shapes_table(), "board-duptest")
  end
end
