defmodule HecateWhiteboardWeb.BoardLive do
  # All view-state is computed here and handed to the template as plain
  # assigns (hosted?, archived?, can_draw?, host_label, stroke_count) --
  # the template and the JS hook only ever render decided state, they
  # never re-derive it. The JS hook is a dumb renderer: it draws whatever
  # strokes it's pushed and reports finished strokes back up; it holds no
  # business logic of its own.
  use Phoenix.LiveView

  alias GuideBoardLifecycle.BoardStatus
  alias GuideBoardLifecycle.DrawStroke.MaybeDrawStroke
  alias GuideBoardLifecycle.HostBoard.MaybeHostBoard
  alias QueryBoards.GetBoardSnapshotById.GetBoardSnapshotById

  # One default board for this walking-skeleton phase -- board creation
  # UX (multiple boards, a picker) is out of scope here; this proves
  # host_board -> draw_stroke -> the browser, not board management.
  #
  # MUST be a real reckon_gater_stream_id shape (<prefix>-<32 hex>), not a
  # human-readable literal -- "board-default" hit exactly the antipattern
  # documented in this repo's own plan doc ({:invalid_stream_id, ...},
  # reckon_db_stream_path:id_nodes/1 crash-looping the store's gateway
  # worker on every read). This one was minted once via
  # reckon_gater_stream_id:new("board") and hardcoded so it's still fixed
  # across restarts.
  @default_board_id "board-01a038649f9470078c0e2afaaaaea200"

  @impl true
  def mount(_params, _session, socket) do
    {:ok, %{board: board, shapes: shapes}} = find_or_host_default_board()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(HecateWhiteboardWeb.PubSub, "board:" <> @default_board_id)
    end

    socket =
      socket
      |> assign(board_id: @default_board_id, page_title: "hecate-whiteboard")
      |> assign(host_label: host_label())
      |> assign(stroke_count: length(shapes))
      |> assign_board_status(board)
      |> push_event("shapes:snapshot", %{shapes: shapes})

    {:ok, socket}
  end

  @impl true
  def handle_event("stroke", %{"points" => points, "color" => color, "width" => width}, socket) do
    MaybeDrawStroke.dispatch(%{
      board_id: socket.assigns.board_id,
      points: points,
      color: color,
      width: width
    })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:board_updated, board}, socket),
    do: {:noreply, assign_board_status(socket, board)}

  def handle_info({:stroke_drawn, stroke}, socket) do
    socket =
      socket
      |> update(:stroke_count, &(&1 + 1))
      |> push_event("shapes:append", stroke)

    {:noreply, socket}
  end

  defp assign_board_status(socket, board) do
    status = board.status

    assign(socket,
      board_title: board.title || "Untitled board",
      hosted?: :evoq_bit_flags.has(status, BoardStatus.hosted()),
      archived?: :evoq_bit_flags.has(status, BoardStatus.archived())
    )
    |> then(fn socket ->
      assign(socket, can_draw?: socket.assigns.hosted? and not socket.assigns.archived?)
    end)
  end

  # Dispatch results aren't re-read from the projection immediately after
  # writing -- evoq_event_handler processes the projection asynchronously,
  # so a read-your-own-write right after dispatch would race it. Instead,
  # reflect the state this process just caused directly; the projection
  # catches up independently for any other reader (a reload, another tab).
  defp find_or_host_default_board do
    case GetBoardSnapshotById.call(@default_board_id) do
      {:ok, %{board: board, shapes: shapes}} ->
        {:ok, %{board: ensure_hosted(board), shapes: shapes}}

      {:error, :not_found} ->
        {:ok, %{board: ensure_hosted(initiate_default_board()), shapes: []}}
    end
  end

  defp ensure_hosted(board) do
    if :evoq_bit_flags.has(board.status, BoardStatus.hosted()) do
      board
    else
      MaybeHostBoard.dispatch(%{board_id: @default_board_id})
      %{board | status: :evoq_bit_flags.set(board.status, BoardStatus.hosted())}
    end
  end

  # The default board's id is fixed (not minted), so it survives a process
  # restart -- deliberate exception to InitiateBoardV1 normally minting
  # one, since there's exactly one board in this phase. Dispatched via the
  # raw evoq primitives rather than MaybeInitiateBoard.dispatch/1, which
  # always mints a fresh id and has no way to accept a caller-supplied one.
  defp initiate_default_board do
    board = %{board_id: @default_board_id, owner: "host", title: "Untitled board"}
    # BoardAggregate.execute/2 pattern-matches on command_type -- forgetting
    # it here (leaving the aggregate-facing payload identical to the
    # returned board shape) is exactly the kind of skew this file's own
    # `find_or_host_default_board` doc comment exists to avoid re-deriving.
    command_payload = Map.put(board, :command_type, :initiate_board)

    :evoq_router.dispatch(
      :evoq_command.new(
        :initiate_board,
        GuideBoardLifecycle.BoardAggregate,
        @default_board_id,
        command_payload
      )
    )

    Map.put(board, :status, :evoq_bit_flags.set(0, BoardStatus.initiated()))
  end

  defp host_label do
    case Node.self() do
      :nonode@nohost -> "local"
      node -> node |> Atom.to_string() |> String.split("@") |> List.last()
    end
  end
end
