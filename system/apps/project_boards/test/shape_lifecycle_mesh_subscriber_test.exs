defmodule ProjectBoards.ShapeLifecycleMeshSubscriberTest do
  # Same atom-vs-{text, _} regression coverage as the old
  # BoardMeshSubscriberTest, plus the same "which topic decides which
  # dispatch clause runs" shape as BoardLifecycleMeshSubscriberTest --
  # this subscriber replaces both BoardMeshSubscriber (one topic, wrote
  # to ETS) and ShapeMeshSubscriber (shared topic, wrote to ETS), so it
  # needs both kinds of coverage at once.
  use ExUnit.Case, async: false

  alias ProjectBoards.ShapeLifecycleMeshSubscriber
  alias ProjectBoards.Store

  @initiated_topic "io.macula/whiteboard-commons/whiteboard/shape_initiated_v1"
  @amended_topic "io.macula/whiteboard-commons/whiteboard/shape_amended_v1"
  @removed_topic "io.macula/whiteboard-commons/whiteboard/shape_removed_v1"

  setup do
    :ets.delete_all_objects(Store.board_shapes_table())
    :ets.delete_all_objects(Store.board_shapes_seen_table())
    :ok
  end

  test "handles an atom-keyed shape_initiated_v1 payload (macula 10.1.1's real shape when the VM already knows the atoms)" do
    payload = %{
      board_id: "board-atomtest",
      shape_id: "s1",
      kind: "stroke",
      points: [%{x: 1, y: 2}],
      color: "#f2efe6",
      width: 3
    }

    assert {:noreply, nil} =
             ShapeLifecycleMeshSubscriber.handle_event(@initiated_topic, payload, %{}, nil)

    assert [{"board-atomtest", %{shape_id: "s1", kind: "stroke", color: "#f2efe6", width: 3}}] =
             :ets.lookup(Store.board_shapes_table(), "board-atomtest")
  end

  test "handles a {:text, _}-tagged shape_initiated_v1 payload (the shape for atoms this VM hasn't loaded)" do
    payload = %{
      {:text, "board_id"} => "board-texttest",
      {:text, "shape_id"} => "s2",
      {:text, "kind"} => {:text, "sticky"},
      {:text, "points"} => [%{{:text, "x"} => 1, {:text, "y"} => 2}],
      {:text, "color"} => {:text, "#d89b4a"},
      {:text, "text"} => {:text, "hello"}
    }

    assert {:noreply, nil} =
             ShapeLifecycleMeshSubscriber.handle_event(@initiated_topic, payload, %{}, nil)

    assert [
             {"board-texttest",
              %{shape_id: "s2", kind: "sticky", color: "#d89b4a", text: "hello"}}
           ] =
             :ets.lookup(Store.board_shapes_table(), "board-texttest")
  end

  test "ignores a payload for an unrelated topic" do
    assert {:noreply, nil} =
             ShapeLifecycleMeshSubscriber.handle_event(
               "some.other.topic",
               %{board_id: "x"},
               %{},
               nil
             )

    assert :ets.lookup(Store.board_shapes_table(), "x") == []
  end

  test "drops a redelivered shape_id instead of storing it twice" do
    # Regression for the catchup-replay bug: a peer's restart re-publishes
    # its full local history to this topic, so the same shape_id arrives
    # more than once. Without the dedup guard this used to re-broadcast
    # (and, if the two deliveries ever differed in shape, double-insert)
    # on every redelivery.
    payload = %{
      board_id: "board-duptest",
      shape_id: "s3",
      kind: "stroke",
      points: [%{x: 1, y: 2}],
      color: "#f2efe6",
      width: 3
    }

    assert {:noreply, nil} =
             ShapeLifecycleMeshSubscriber.handle_event(@initiated_topic, payload, %{}, nil)

    assert {:noreply, nil} =
             ShapeLifecycleMeshSubscriber.handle_event(@initiated_topic, payload, %{}, nil)

    assert [{"board-duptest", %{shape_id: "s3"}}] =
             :ets.lookup(Store.board_shapes_table(), "board-duptest")
  end

  test "shape_amended_v1 moves an already-stored shape's points" do
    :ets.insert(
      Store.board_shapes_table(),
      {"board-movetest", %{shape_id: "s4", kind: "sticky", points: [%{x: 0, y: 0}]}}
    )

    payload = %{board_id: "board-movetest", shape_id: "s4", points: [%{x: 9, y: 9}]}

    assert {:noreply, nil} =
             ShapeLifecycleMeshSubscriber.handle_event(@amended_topic, payload, %{}, nil)

    assert [{"board-movetest", %{shape_id: "s4", points: [%{x: 9, y: 9}]}}] =
             :ets.lookup(Store.board_shapes_table(), "board-movetest")
  end

  test "shape_removed_v1 deletes an already-stored shape" do
    :ets.insert(
      Store.board_shapes_table(),
      {"board-removetest", %{shape_id: "s5", kind: "sticky", points: [%{x: 0, y: 0}]}}
    )

    payload = %{board_id: "board-removetest", shape_id: "s5"}

    assert {:noreply, nil} =
             ShapeLifecycleMeshSubscriber.handle_event(@removed_topic, payload, %{}, nil)

    assert :ets.lookup(Store.board_shapes_table(), "board-removetest") == []
  end
end
