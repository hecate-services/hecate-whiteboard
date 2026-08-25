defmodule ProjectBoards.Store do
  # ETS read-model facade, mirrors hecate-tube's project_tube_store pattern.
  # Owns two public named tables so projections and query_boards' desks can
  # read/write directly without routing every operation through this
  # process -- this process only exists to own the tables' lifetime.
  #
  # :boards       set  board_id => %{owner, title, status}
  # :board_shapes bag  board_id => stroke map (one entry per stroke)
  use GenServer

  @boards :boards
  @board_shapes :board_shapes

  def boards_table, do: @boards
  def board_shapes_table, do: @board_shapes

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init([]) do
    :ets.new(@boards, [:set, :public, :named_table, read_concurrency: true])
    :ets.new(@board_shapes, [:bag, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end
end
