defmodule ProjectBoards.Store do
  # ETS read-model facade, mirrors hecate-tube's project_tube_store pattern.
  # Owns three public named tables so projections and query_boards' desks
  # can read/write directly without routing every operation through this
  # process -- this process only exists to own the tables' lifetime.
  #
  # :boards             set  board_id => %{owner, title, status}
  # :board_shapes       bag  board_id => stroke map (one entry per stroke)
  # :board_strokes_seen set  stroke_id => true
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
  use GenServer

  @boards :boards
  @board_shapes :board_shapes
  @board_strokes_seen :board_strokes_seen

  def boards_table, do: @boards
  def board_shapes_table, do: @board_shapes
  def board_strokes_seen_table, do: @board_strokes_seen

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init([]) do
    :ets.new(@boards, [:set, :public, :named_table, read_concurrency: true])
    :ets.new(@board_shapes, [:bag, :public, :named_table, read_concurrency: true])
    :ets.new(@board_strokes_seen, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  # Atomic "have we stored this stroke before" check-and-set. Both writers
  # (the local projection and the mesh subscriber) call this before
  # touching board_shapes or broadcasting -- true means genuinely new,
  # false means a redelivery to skip.
  def new_stroke?(stroke_id), do: :ets.insert_new(@board_strokes_seen, {stroke_id})
end
