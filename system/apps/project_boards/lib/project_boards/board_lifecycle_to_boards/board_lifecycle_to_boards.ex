defmodule ProjectBoards.BoardLifecycleToBoards.BoardLifecycleToBoards do
  # Projects board_initiated_v1/board_hosted_v1/board_archived_v1 onto the
  # `boards` ETS table. Broadcasts each write to this board's PubSub topic
  # so a live LiveView reflects host/archive transitions without polling.
  #
  # @behaviour :evoq_event_handler, NOT :evoq_projection -- the latter's
  # interested_in/init/project shape (init/1 -> {ok, State, ReadModel})
  # was only ever documented, never exercised. evoq_event_handler is what
  # hecate-tube's own supervisor actually starts, and its real contract
  # (confirmed by reading evoq_event_router.erl/evoq_event_handler.erl
  # directly) is interested_in/0, init/1 -> {ok, State}, handle_event/4.
  @behaviour :evoq_event_handler

  alias ProjectBoards.Store

  @impl true
  def interested_in, do: ["board_initiated_v1", "board_hosted_v1", "board_archived_v1"]

  @impl true
  def init(_config), do: {:ok, %{}}

  # Event still arrives as the wrapped store record (event_type, data,
  # stream_id, version, ...) -- evoq_event_router passes the SAME map it
  # reads event_type off of straight through to handle_event/4, it does
  # not unwrap `data` first. See "event shape on the wire" in
  # plans/PLAN_HECATE_WHITEBOARD_ROOT.md.
  @impl true
  def handle_event(event_type, event, _metadata, state) do
    data = field(:data, event)
    board_id = field(:board_id, data)
    table = Store.boards_table()

    existing =
      case :ets.lookup(table, board_id) do
        [{^board_id, row}] -> row
        [] -> %{owner: nil, title: nil, status: 0}
      end

    updated = apply_event(event_type, existing, data)
    :ets.insert(table, {board_id, updated})

    Phoenix.PubSub.broadcast(
      HecateWhiteboardWeb.PubSub,
      "board:" <> board_id,
      {:board_updated, updated}
    )

    {:ok, state}
  end

  defp apply_event("board_initiated_v1", row, data) do
    %{
      row
      | owner: field(:owner, data),
        title: field(:title, data),
        status: :evoq_bit_flags.set(row.status, 1)
    }
  end

  defp apply_event("board_hosted_v1", row, _data),
    do: %{row | status: :evoq_bit_flags.set(row.status, 4)}

  defp apply_event("board_archived_v1", row, _data),
    do: %{row | status: :evoq_bit_flags.set(row.status, 2)}

  defp field(key, map) when is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end
end
