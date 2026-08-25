defmodule QueryBoards.AnswerBoardSnapshotQueries do
  # Host half of join_board's mesh discovery. Permanently subscribed to
  # the fixed board_snapshot_query_v1 topic; every host on the mesh gets
  # every query (board_id lives in the payload, not the topic, same
  # convention as StrokeDrawnV1ToMesh/BoardMeshSubscriber). Only a node
  # that actually hosts the requested board_id answers.
  #
  # "Actually hosts" is decided by GetBoardSnapshotById returning a row at
  # all: BoardMeshSubscriber only ever writes into board_shapes (strokes),
  # never into the boards table, so a pure mesh-replica peer that has
  # never itself run initiate_board/host_board for this board_id has NO
  # boards row and GetBoardSnapshotById correctly reports :not_found for
  # it -- no separate "am I a replica vs a host" flag needed, the read
  # model shape already encodes that distinction. Archived boards also
  # decline to answer, same as a client can't draw on one (BoardLive's
  # can_draw? logic).
  @behaviour :macula_subscriber

  alias GuideBoardLifecycle.BoardStatus
  alias QueryBoards.GetBoardSnapshotById.GetBoardSnapshotById
  alias QueryBoards.GetBoardSnapshotByIdOverMesh.GetBoardSnapshotByIdOverMesh

  require Logger

  def topic, do: GetBoardSnapshotByIdOverMesh.query_topic()

  @impl true
  def init(_args), do: {:ok, nil}

  @impl true
  def handle_event(topic, payload, _meta, state) do
    if topic == GetBoardSnapshotByIdOverMesh.query_topic() do
      fact = normalize(payload)
      answer(field(:board_id, fact), field(:reply_to, fact))
    end

    {:noreply, state}
  end

  defp answer(board_id, reply_to) when is_binary(board_id) and is_binary(reply_to) do
    case GetBoardSnapshotById.call(board_id) do
      {:ok, %{board: board} = snapshot} -> maybe_reply(board, snapshot, reply_to)
      {:error, :not_found} -> :ok
    end
  end

  defp answer(_board_id, _reply_to), do: :ok

  defp maybe_reply(board, snapshot, reply_to) do
    if authoritative_here?(board), do: reply(snapshot, reply_to)
  end

  # Split out from maybe_reply/3 so the gating decision is testable
  # without a live mesh -- reply/2's own mesh_handles() call can't run
  # outside a real pool, but this can and is what's actually worth
  # verifying (hosted+non-archived answers, archived and not-hosted-here
  # both stay silent).
  def authoritative_here?(%{status: status}) do
    hosted? = :evoq_bit_flags.has(status, BoardStatus.hosted())
    archived? = :evoq_bit_flags.has(status, BoardStatus.archived())
    hosted? and not archived?
  end

  defp reply(%{board: board, shapes: shapes, as_of_version: as_of_version}, reply_to) do
    fact = %{
      board_id: board.board_id,
      owner: board.owner,
      title: board.title,
      status: board.status,
      shapes: shapes,
      as_of_version: as_of_version
    }

    case :hecate_om.mesh_handles() do
      {:ok, pool, realm} ->
        result =
          :macula_publisher.start_link(QueryBoards.MeshPublisher, pool, realm, reply_to, fact, [])

        Logger.info("[AnswerBoardSnapshotQueries] reply #{board.board_id}: #{inspect(result)}")

      other ->
        Logger.warning(
          "[AnswerBoardSnapshotQueries] mesh_handles: #{inspect(other)}, dropping reply"
        )
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
