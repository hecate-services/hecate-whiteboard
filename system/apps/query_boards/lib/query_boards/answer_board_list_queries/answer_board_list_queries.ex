defmodule QueryBoards.AnswerBoardListQueries do
  # Host half of the mesh-aware board picker: every node on the mesh is
  # permanently subscribed to this fixed query topic. Unlike
  # AnswerBoardSnapshotQueries (join_board's responder, gated on "do I
  # actually host this ONE board_id"), there is no authority question
  # here -- "what do I host" is always a safe, truthful answer, so every
  # node with at least one hosted board replies. A query for a specific
  # board expects exactly one authoritative answer; a query for "what
  # exists" expects an answer from everyone who has something to say, so
  # the client (ListBoardsOverMesh) collects for a fixed window instead
  # of stopping at the first reply.
  @behaviour :macula_subscriber

  alias QueryBoards.ListHostedBoards.ListHostedBoards

  require Logger

  @query_topic "io.macula/whiteboard-commons/whiteboard/board_list_query_v1"

  def topic, do: @query_topic

  @impl true
  def init(_args), do: {:ok, nil}

  @impl true
  def handle_event(topic, payload, _meta, state) do
    if topic == @query_topic do
      fact = normalize(payload)
      reply(field(:reply_to, fact))
    end

    {:noreply, state}
  end

  defp reply(reply_to) when is_binary(reply_to) do
    case ListHostedBoards.call() do
      [] ->
        :ok

      boards ->
        fact = %{host: host_label(), boards: Enum.map(boards, &board_fact/1)}

        case :hecate_om.mesh_handles() do
          {:ok, pool, realm} ->
            result =
              :macula_publisher.start_link(
                QueryBoards.MeshPublisher,
                pool,
                realm,
                reply_to,
                fact,
                []
              )

            Logger.info(
              "[AnswerBoardListQueries] reply #{length(boards)} boards: #{inspect(result)}"
            )

          other ->
            Logger.warning(
              "[AnswerBoardListQueries] mesh_handles: #{inspect(other)}, dropping reply"
            )
        end
    end
  end

  defp reply(_reply_to), do: :ok

  defp board_fact(board) do
    %{
      board_id: board.board_id,
      title: board.title,
      owner: board.owner,
      stroke_count: board.stroke_count
    }
  end

  # Same host-name derivation as HecateWhiteboardWeb.BoardLive/
  # GuideBoardLifecycle.BoardAggregate's own host_label -- duplicated
  # rather than shared, matching this module's own convention elsewhere
  # in the app.
  defp host_label do
    case Node.self() do
      :nonode@nohost -> "local"
      node -> node |> Atom.to_string() |> String.split("@") |> List.last()
    end
  end

  defp field(key, map) when is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp normalize({:text, b}) when is_binary(b), do: b
  defp normalize(:undefined), do: nil
  defp normalize(m) when is_map(m), do: Map.new(m, fn {k, v} -> {normalize(k), normalize(v)} end)
  defp normalize(l) when is_list(l), do: Enum.map(l, &normalize/1)
  defp normalize(v), do: v
end
