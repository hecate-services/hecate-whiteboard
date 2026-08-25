defmodule GuideBoardLifecycle.BoardLifecycleV1ToMesh do
  # Republishes every LOCALLY-originated board_initiated_v1/
  # board_hosted_v1/board_archived_v1/board_renamed_v1 as a mesh fact, so
  # the board picker (HecateWhiteboardWeb.BoardsLive, "on other nodes")
  # updates live instead of only ever reflecting whatever a one-shot
  # mesh query saw at page load.
  #
  # One topic PER event type, named after the event -- matches
  # StrokeDrawnV1ToMesh's own precedent, not ShapeMutatedV1ToMesh's
  # shared-topic one. Those five shape events are genuine variations of
  # one concern ("what's drawn on this board changed"); these four are
  # not -- "created", "became permanently read-only", and "renamed" are
  # distinct kinds of news a future consumer may well want to subscribe
  # to selectively, not a family worth forcing through one filter.
  #
  # Deliberately does NOT change how board creation itself works --
  # HecateWhiteboardWeb.BoardsLive's create_board/1 still dispatches
  # initiate_board and host_board back-to-back, synchronously, same as
  # before. The two facts this produces just happen to land on the mesh
  # a few milliseconds apart -- true, honest eventual consistency, not
  # a new deferred-hosting mechanic. A remote peer that happens to catch
  # a board between the two (initiated, not yet hosted) sees exactly
  # that: see BoardsLive's own comment on why an initiated-not-hosted
  # remote board renders as a badge, not a link.
  @behaviour :evoq_event_handler

  @topics %{
    "board_initiated_v1" => "io.macula/whiteboard-commons/whiteboard/board_initiated_v1",
    "board_hosted_v1" => "io.macula/whiteboard-commons/whiteboard/board_hosted_v1",
    "board_archived_v1" => "io.macula/whiteboard-commons/whiteboard/board_archived_v1",
    "board_renamed_v1" => "io.macula/whiteboard-commons/whiteboard/board_renamed_v1"
  }

  def topic(event_type), do: Map.fetch!(@topics, event_type)
  def topics, do: @topics

  @impl true
  def interested_in, do: Map.keys(@topics)

  @impl true
  def init(_config), do: {:ok, %{}}

  @impl true
  def handle_event(event_type, event, _metadata, state) do
    data = field(:data, event)

    fact = %{
      board_id: field(:board_id, data),
      # Only board_initiated_v1 carries owner, only board_initiated_v1/
      # board_renamed_v1 carry title -- nil on every other event type,
      # which the receiving side treats as "no update" rather than
      # "clear this field". See HecateWhiteboardWeb.BoardsLive's own
      # accumulation logic.
      title: field(:title, data),
      owner: field(:owner, data),
      host: host_label()
    }

    publish(event_type, fact)
    {:ok, state}
  end

  defp publish(event_type, fact) do
    require Logger

    case :hecate_om.mesh_handles() do
      {:ok, pool, realm} ->
        result =
          :macula_publisher.start_link(
            GuideBoardLifecycle.MeshPublisher,
            pool,
            realm,
            topic(event_type),
            fact,
            []
          )

        Logger.info(
          "[BoardLifecycleV1ToMesh] publish #{event_type} #{fact.board_id}: #{inspect(result)}"
        )

        :ok

      other ->
        Logger.warning(
          "[BoardLifecycleV1ToMesh] mesh_handles: #{inspect(other)}, dropping publish"
        )

        :ok
    end
  end

  # Same host-name derivation as HecateWhiteboardWeb.BoardLive/
  # QueryBoards.AnswerBoardListQueries's own host_label -- duplicated
  # rather than shared, matching this workspace's existing convention
  # for this exact helper.
  defp host_label do
    case Node.self() do
      :nonode@nohost -> "local"
      node -> node |> Atom.to_string() |> String.split("@") |> List.last()
    end
  end

  defp field(key, map) when is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end
end
