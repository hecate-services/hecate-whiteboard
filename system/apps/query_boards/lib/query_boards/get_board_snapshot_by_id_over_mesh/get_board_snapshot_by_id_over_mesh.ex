defmodule QueryBoards.GetBoardSnapshotByIdOverMesh.GetBoardSnapshotByIdOverMesh do
  # Client half of join_board's mesh-level discovery: this node doesn't
  # host board_id locally (GetBoardSnapshotById returned :not_found), so
  # ask the mesh who does. Publishes a query naming a fresh per-call reply
  # topic, subscribes to that reply topic FIRST (so a fast responder can't
  # answer before we're listening), then waits. Whichever host actually
  # hosts board_id answers on AnswerBoardSnapshotQueries's own subscriber
  # (see that module) with the snapshot itself -- one round trip, no
  # separate "who hosts this" step followed by a second RPC, since the
  # answer already carries everything a join needs.
  #
  # Both directions go through the supervised macula_publisher/
  # macula_subscriber pairs (QueryBoards.MeshPublisher,
  # QueryBoards.OneShotMeshReply) -- never a raw macula:publish/4 or
  # macula:subscribe/5 call here, matching every other mesh integration
  # point in this app.
  #
  # A successful reply is materialized into project_boards' own ETS
  # tables before returning, through the SAME Store.new_shape?/1 dedup
  # gate the local projection and the mesh subscribers use -- so BoardLive
  # can call this exactly like GetBoardSnapshotById and get the identical
  # shape back, and a page reload after a join reads locally with no
  # repeat mesh round trip.
  alias GuideBoardLifecycle.BoardStatus
  alias ProjectBoards.Store
  alias QueryBoards.GetBoardSnapshotById.GetBoardSnapshotById

  require Logger

  @query_topic "io.macula/whiteboard-commons/whiteboard/board_snapshot_query_v1"
  @reply_topic_prefix "io.macula/whiteboard-commons/whiteboard/board_snapshot_reply/"

  def query_topic, do: @query_topic

  @default_timeout_ms 3_000

  def call(board_id, timeout_ms \\ @default_timeout_ms) do
    case :hecate_om.mesh_handles() do
      {:ok, pool, realm} -> query(pool, realm, board_id, timeout_ms)
      other -> {:error, {:mesh_unavailable, other}}
    end
  end

  defp query(pool, realm, board_id, timeout_ms) do
    reply_topic = @reply_topic_prefix <> random_id()

    case :macula_subscriber.start_link(
           QueryBoards.OneShotMeshReply,
           pool,
           realm,
           reply_topic,
           self()
         ) do
      {:ok, subscriber} ->
        publish_query(pool, realm, board_id, reply_topic)
        await_reply(subscriber, timeout_ms)

      {:error, reason} ->
        {:error, {:reply_subscribe_failed, reason}}
    end
  end

  defp publish_query(pool, realm, board_id, reply_topic) do
    fact = %{board_id: board_id, reply_to: reply_topic}

    result =
      :macula_publisher.start_link(QueryBoards.MeshPublisher, pool, realm, @query_topic, fact, [])

    Logger.info("[GetBoardSnapshotByIdOverMesh] query #{board_id}: #{inspect(result)}")
  end

  defp await_reply(subscriber, timeout_ms) do
    receive do
      {:one_shot_mesh_reply, payload} -> materialize(normalize(payload))
    after
      timeout_ms ->
        if Process.alive?(subscriber), do: GenServer.stop(subscriber)
        {:error, :no_host_found}
    end
  end

  defp materialize(fact) do
    board_id = field(:board_id, fact)

    board = %{
      board_id: board_id,
      owner: field(:owner, fact),
      title: field(:title, fact),
      # Deliberately NOT the host's own status bits -- this node is not
      # the aggregate authority for board_id, so `hosted` must read false
      # here regardless of what the real host's status says.
      # BoardLive's existing can_draw? = hosted? and not archived? then
      # makes a joined board correctly read-only with no template change.
      status: BoardStatus.initiated()
    }

    :ets.insert(Store.boards_table(), {board_id, board})

    (field(:shapes, fact) || [])
    |> Enum.map(&normalize_shape/1)
    |> Enum.filter(&Store.new_shape?(&1.shape_id))
    |> Enum.each(&:ets.insert(Store.board_shapes_table(), {board_id, &1}))

    Store.note_stroke_version(board_id, field(:as_of_version, fact) || 0)

    # Read back through the same desk the local-host mount path uses, so
    # both of BoardLive's mount branches return an identical shape.
    GetBoardSnapshotById.call(board_id)
  end

  # A snapshot's `shapes` list is every kind (stroke/sticky/text/
  # rectangle/ellipse/triangle) mixed together, not just strokes -- this
  # used to be normalize_stroke/1, extracting only stroke_id/points/
  # color/width, from back when join_board predated any non-stroke
  # shape. Left unfixed, every non-stroke shape came out with kind,
  # shape_id, and text silently dropped (replaced by a stroke_id that
  # never existed for it, always nil), AND all but the FIRST such shape
  # in the list vanished outright: new_shape?(nil) is only true once, so
  # every non-stroke shape after the first collided on the same nil key
  # and got filtered out as an apparent "redelivery". Found live:
  # msi00's join snapshot of a board with a rectangle and four stickies
  # came back with the rectangle missing entirely and only one
  # corrupted, textless sticky surviving.
  #
  # Exported for testing only -- pure, no store or mesh needed.
  def normalize_shape(shape) do
    shape_id = field(:shape_id, shape) || field(:stroke_id, shape)

    %{
      kind: field(:kind, shape) || "stroke",
      shape_id: shape_id,
      stroke_id: field(:stroke_id, shape),
      points: field(:points, shape),
      color: field(:color, shape),
      width: field(:width, shape),
      text: field(:text, shape)
    }
  end

  # Same atom/{text,_} tolerance as every other mesh-facing module here --
  # see BoardMeshSubscriber's header comment for the full explanation.
  defp field(key, map) when is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp normalize({:text, b}) when is_binary(b), do: b
  defp normalize(:undefined), do: nil
  defp normalize(m) when is_map(m), do: Map.new(m, fn {k, v} -> {normalize(k), normalize(v)} end)
  defp normalize(l) when is_list(l), do: Enum.map(l, &normalize/1)
  defp normalize(v), do: v

  defp random_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
