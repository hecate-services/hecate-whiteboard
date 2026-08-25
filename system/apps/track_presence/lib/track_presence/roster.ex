defmodule TrackPresence.Roster do
  # ETS-backed presence roster -- one row per {board_id, peer_id}, holding
  # where that peer's cursor last came to rest. Deliberately NOT
  # event-sourced (see plans/PLAN_HECATE_WHITEBOARD_ROOT.md's "Presence is
  # not event-sourced" decision): this is ephemeral session state, aged
  # out by Sweep, never written to the event store. The one exception
  # (leave_board -> peer_departed_v1) lives in guide_board_lifecycle, not
  # here -- this module only owns the roster and the mesh-wide "here's
  # where I am" fact.
  #
  # touch/1 is for a LOCALLY-originated settle (this node's own LiveView
  # calling in after its JS hook debounced a pointer stop) -- it writes
  # the row, broadcasts locally, AND publishes to mesh. absorb_remote/1 is
  # for a fact arriving FROM the mesh -- writes the row and broadcasts
  # locally only, never re-publishes. That asymmetry is what keeps this
  # loop-free, same trick ShapeLifecycleMeshSubscriber uses for shapes.
  use GenServer

  require Logger

  @cursors :presence_cursors

  # A settled position older than this is stale enough to age out even if
  # its owning peer's own LiveView never got a chance to say goodbye
  # (network drop, browser crash) -- well above the ~400ms settle debounce
  # plus normal jitter, short enough that a genuinely-gone peer's cursor
  # doesn't linger looking live. Tunable; not load-bearing for anything
  # else.
  @stale_after_ms 20_000

  def cursors_table, do: @cursors
  def stale_after_ms, do: @stale_after_ms

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init([]) do
    :ets.new(@cursors, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  def touch(%{board_id: board_id} = fact) do
    write(fact)
    broadcast_locally(board_id, {:cursor_settled, board_id, present(fact)})
    publish_to_mesh(fact)
    :ok
  end

  def absorb_remote(%{board_id: board_id} = fact) do
    write(fact)
    broadcast_locally(board_id, {:cursor_settled, board_id, present(fact)})
    :ok
  end

  def remove(board_id, peer_id) do
    case :ets.take(@cursors, {board_id, peer_id}) do
      [_] -> broadcast_locally(board_id, {:cursor_left, board_id, peer_id})
      [] -> :ok
    end

    :ok
  end

  def list_for_board(board_id) do
    :ets.match_object(@cursors, {{board_id, :_}, :_})
    |> Enum.map(fn {{^board_id, peer_id}, row} -> present(Map.put(row, :peer_id, peer_id)) end)
  end

  # Called by Sweep on its own timer -- every node ages out its own roster
  # independently, whether a row came from a local touch or an absorbed
  # remote fact, so no cross-node coordination is needed for the ambient
  # (non-graceful) departure case.
  def sweep(now_ms \\ System.system_time(:millisecond)) do
    :ets.tab2list(@cursors)
    |> Enum.filter(fn {_key, row} -> now_ms - row.last_seen > @stale_after_ms end)
    |> Enum.each(fn {{board_id, peer_id}, _row} -> remove(board_id, peer_id) end)
  end

  defp write(%{board_id: board_id, peer_id: peer_id} = fact) do
    row = %{
      x: fact.x,
      y: fact.y,
      color: fact.color,
      label: fact.label,
      last_seen: System.system_time(:millisecond)
    }

    :ets.insert(@cursors, {{board_id, peer_id}, row})
  end

  defp present(%{peer_id: peer_id, x: x, y: y, color: color, label: label}) do
    %{peer_id: peer_id, x: x, y: y, color: color, label: label}
  end

  defp broadcast_locally(board_id, message) do
    Phoenix.PubSub.broadcast(HecateWhiteboardWeb.PubSub, "board:" <> board_id, message)
  end

  @topic "io.macula/whiteboard-commons/whiteboard/cursor_settled_v1"

  def topic, do: @topic

  defp publish_to_mesh(fact) do
    case :hecate_om.mesh_handles() do
      {:ok, pool, realm} ->
        result =
          :macula_publisher.start_link(
            TrackPresence.MeshPublisher,
            pool,
            realm,
            @topic,
            Map.take(fact, [:board_id, :peer_id, :x, :y, :color, :label]),
            []
          )

        Logger.debug("[Roster] publish #{fact.peer_id}: #{inspect(result)}")
        :ok

      other ->
        Logger.debug("[Roster] mesh_handles: #{inspect(other)}, dropping publish")
        :ok
    end
  end
end
