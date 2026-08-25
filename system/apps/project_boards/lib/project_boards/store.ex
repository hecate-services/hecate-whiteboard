defmodule ProjectBoards.Store do
  # ETS read-model facade, mirrors hecate-tube's project_tube_store pattern.
  # Owns four public named tables so projections and query_boards' desks
  # can read/write directly without routing every operation through this
  # process -- this process only exists to own the tables' lifetime.
  #
  # :boards               set  board_id => %{owner, title, status}
  # :board_shapes         bag  board_id => stroke map (one entry per stroke)
  # :board_strokes_seen   set  stroke_id => true
  # :board_stroke_versions set board_id => latest applied stroke's evoq version
  #
  # board_strokes_seen exists purely for :ets.insert_new/2's atomic
  # check-and-set -- stroke_id is globally random (DrawStrokeV1.random_id/0,
  # not board-scoped), so one flat set covers every board. Without it,
  # evoq's catchup replay on restart re-delivers a host's full local
  # history through the same handle_event path (see
  # StrokeDrawnV1ToBoardShapes and BoardMeshSubscriber, the two writers),
  # which re-broadcasts every historical stroke to any currently-connected
  # LiveView -- board_shapes itself mostly self-heals (a bag won't store a
  # second identical tuple), but the broadcast has no such guard and isn't
  # a table operation, so it happened on every redelivery regardless.
  #
  # board_stroke_versions backs join_board's as_of_version (see
  # QueryBoards.GetBoardSnapshotByIdOverMesh) -- evoq hands every projection
  # handler the wrapped event's own top-level `version`, so this just
  # remembers the highest one genuinely applied per board_id. It only needs
  # to track stroke versions specifically: as_of_version exists so a
  # joining client can drop already-applied stroke_drawn_v1 events out of
  # whatever it buffered from the live mesh subscription during the join
  # round trip, and stroke_drawn_v1 is the only event type that subscription
  # carries.
  use GenServer

  @boards :boards
  @board_shapes :board_shapes
  @board_strokes_seen :board_strokes_seen
  @board_stroke_versions :board_stroke_versions

  def boards_table, do: @boards
  def board_shapes_table, do: @board_shapes
  def board_strokes_seen_table, do: @board_strokes_seen
  def board_stroke_versions_table, do: @board_stroke_versions

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init([]) do
    :ets.new(@boards, [:set, :public, :named_table, read_concurrency: true])
    :ets.new(@board_shapes, [:bag, :public, :named_table, read_concurrency: true])
    :ets.new(@board_strokes_seen, [:set, :public, :named_table, read_concurrency: true])
    :ets.new(@board_stroke_versions, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  # Atomic "have we stored this stroke before" check-and-set. Both writers
  # (the local projection and the mesh subscriber) call this before
  # touching board_shapes or broadcasting -- true means genuinely new,
  # false means a redelivery to skip.
  def new_stroke?(stroke_id), do: :ets.insert_new(@board_strokes_seen, {stroke_id})

  # evoq delivers events in stream order per board, so the last call for
  # a given board_id IS its latest version -- no max-guard needed.
  def note_stroke_version(board_id, version), do: :ets.insert(@board_stroke_versions, {board_id, version})

  def stroke_version(board_id) do
    case :ets.lookup(@board_stroke_versions, board_id) do
      [{^board_id, v}] -> v
      [] -> 0
    end
  end
end
