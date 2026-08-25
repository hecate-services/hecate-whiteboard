defmodule QueryBoards.ListBoardsOverMesh.ListBoardsOverMesh do
  # Client half of the mesh-aware board picker. Unlike
  # GetBoardSnapshotByIdOverMesh (join_board's query, which stops at the
  # first authoritative reply), a board-list query has no single correct
  # answerer -- every node that hosts something may reply -- so this
  # collects for a FIXED WINDOW instead of stopping early, then merges
  # what came back. Same supervised publish/subscribe pattern as every
  # other mesh integration point here (QueryBoards.MeshPublisher,
  # QueryBoards.ManyShotMeshReply), never a raw macula:publish/4 or
  # macula:subscribe/5 call.
  #
  # Meant to run off the LiveView's main process (see
  # HecateWhiteboardWeb.BoardsLive's use of start_async/3) -- this
  # function blocks its caller for up to timeout_ms, which would freeze
  # a LiveView's own mailbox for that whole window if called directly
  # from mount/handle_event.
  require Logger

  alias QueryBoards.AnswerBoardListQueries

  @default_timeout_ms 1_500

  def call(timeout_ms \\ @default_timeout_ms) do
    case :hecate_om.mesh_handles() do
      {:ok, pool, realm} -> query(pool, realm, timeout_ms)
      other -> {:error, {:mesh_unavailable, other}}
    end
  end

  defp query(pool, realm, timeout_ms) do
    reply_topic = "io.macula/whiteboard-commons/whiteboard/board_list_reply/" <> random_id()

    case :macula_subscriber.start_link(
           QueryBoards.ManyShotMeshReply,
           pool,
           realm,
           reply_topic,
           self()
         ) do
      {:ok, subscriber} ->
        publish_query(pool, realm, reply_topic)
        boards = collect(deadline(timeout_ms), [])
        if Process.alive?(subscriber), do: GenServer.stop(subscriber)
        {:ok, boards}

      {:error, reason} ->
        {:error, {:reply_subscribe_failed, reason}}
    end
  end

  defp publish_query(pool, realm, reply_topic) do
    fact = %{reply_to: reply_topic}

    result =
      :macula_publisher.start_link(
        QueryBoards.MeshPublisher,
        pool,
        realm,
        AnswerBoardListQueries.topic(),
        fact,
        []
      )

    Logger.info("[ListBoardsOverMesh] query: #{inspect(result)}")
  end

  defp deadline(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms

  defp collect(deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      merge(acc)
    else
      receive do
        {:mesh_reply, payload} -> collect(deadline, [normalize(payload) | acc])
      after
        remaining -> merge(acc)
      end
    end
  end

  # One reply per host, each carrying a list of boards -- flatten, tag
  # each board with which host answered, then dedup by board_id (the
  # fixed default board is legitimately hosted by more than one peer
  # under today's symmetric-gossip replication -- see the plan doc's
  # "Basic mesh replication" section -- so more than one host answering
  # for the SAME board_id is expected, not an error; first answer wins).
  #
  # Exported for testing only -- pure, no store or mesh needed; collect/2
  # and everything upstream of it needs a live pool to exercise.
  def merge(replies) do
    replies
    |> Enum.flat_map(fn fact ->
      host = field(:host, fact)
      (field(:boards, fact) || []) |> Enum.map(&Map.put(normalize_board(&1), :host, host))
    end)
    |> Enum.uniq_by(& &1.board_id)
    |> Enum.sort_by(& &1.title)
  end

  defp normalize_board(board) do
    %{
      board_id: field(:board_id, board),
      title: field(:title, board),
      owner: field(:owner, board),
      stroke_count: field(:stroke_count, board) || 0
    }
  end

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
