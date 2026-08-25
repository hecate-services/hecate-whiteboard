defmodule ProjectBoards.BoardLifecycleMeshSubscriberTest do
  # Same atom-vs-{text, _} regression coverage as BoardMeshSubscriberTest,
  # plus the one thing genuinely specific to this subscriber: which of
  # its four topics a payload arrived on becomes the event_type in the
  # local re-broadcast, since (unlike BoardMeshSubscriber's one topic)
  # there's no single @topic to hardcode into handle_event's own guard.
  use ExUnit.Case, async: false

  alias ProjectBoards.BoardLifecycleMeshSubscriber

  @hosted_topic "io.macula/whiteboard-commons/whiteboard/board_hosted_v1"
  @initiated_topic "io.macula/whiteboard-commons/whiteboard/board_initiated_v1"

  setup do
    Phoenix.PubSub.subscribe(HecateWhiteboardWeb.PubSub, "boards:remote")
    :ok
  end

  test "re-broadcasts an atom-keyed payload with event_type derived from the topic" do
    payload = %{board_id: "board-atomtest", title: "Retro", owner: "beam02", host: "beam02"}

    assert {:noreply, nil} =
             BoardLifecycleMeshSubscriber.handle_event(@hosted_topic, payload, %{}, nil)

    assert_receive {:remote_board_event, "board_hosted_v1",
                    %{board_id: "board-atomtest", title: "Retro"}}
  end

  test "re-broadcasts a {:text, _}-tagged payload" do
    payload = %{
      {:text, "board_id"} => "board-texttest",
      {:text, "title"} => {:text, "Retro"},
      {:text, "owner"} => {:text, "beam02"},
      {:text, "host"} => {:text, "beam02"}
    }

    assert {:noreply, nil} =
             BoardLifecycleMeshSubscriber.handle_event(@initiated_topic, payload, %{}, nil)

    assert_receive {:remote_board_event, "board_initiated_v1",
                    %{board_id: "board-texttest", title: "Retro"}}
  end

  test "ignores a payload for an unrelated topic" do
    assert {:noreply, nil} =
             BoardLifecycleMeshSubscriber.handle_event(
               "some.other.topic",
               %{board_id: "x"},
               %{},
               nil
             )

    refute_receive {:remote_board_event, _, _}
  end
end
