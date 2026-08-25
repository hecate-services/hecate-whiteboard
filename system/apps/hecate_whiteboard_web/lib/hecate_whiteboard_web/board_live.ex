defmodule HecateWhiteboardWeb.BoardLive do
  # All view-state is computed here and handed to the template as plain
  # assigns (hosted?, archived?, can_draw?, can_rename?, status_dot,
  # status_hint, host_label, stroke_count) -- the template and the JS
  # hook only ever render decided state, they never re-derive it. The JS
  # hook is a dumb renderer: it draws whatever strokes it's pushed and
  # reports finished strokes back up; it holds no business logic of its
  # own.
  #
  # can_draw? and can_rename? deliberately diverge: renaming stays
  # authority-only (can_rename? = hosted? and not archived?, unchanged
  # from this file's original single can_draw? flag), but drawing is now
  # possible on a board this node doesn't host too -- see
  # GuideBoardLifecycle.DrawStroke.MaybeDrawStroke.relay/1 and
  # AnswerDrawStrokeRequests for the write-relay this enables. Renaming
  # a remote board isn't built; broadening can_draw? without a matching
  # can_rename? would have silently done that by accident.
  use Phoenix.LiveView

  alias GuideBoardLifecycle.BoardStatus
  alias GuideBoardLifecycle.DrawStroke.MaybeDrawStroke
  alias GuideBoardLifecycle.HostBoard.MaybeHostBoard
  alias GuideBoardLifecycle.RenameBoard.MaybeRenameBoard
  alias QueryBoards.GetBoardSnapshotById.GetBoardSnapshotById
  alias QueryBoards.GetBoardSnapshotByIdOverMesh.GetBoardSnapshotByIdOverMesh

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

  # join_board: a specific board_id from the URL, not necessarily hosted
  # on this node. Tries the local read model first (covers: this node IS
  # the host, or already joined this board_id once before) and only asks
  # the mesh when that comes back empty -- see
  # GetBoardSnapshotByIdOverMesh's own header for the discovery protocol
  # and why the two mount clauses can return an identical snapshot shape.
  # A board nobody on the mesh answers for redirects to the default board
  # rather than stranding the visitor on a dead page.
  @impl true
  def mount(%{"board_id" => board_id}, _session, socket) do
    case find_or_join_board(board_id) do
      {:ok, %{board: board, shapes: shapes}} ->
        {:ok, render_board(socket, board_id, board, shapes)}

      {:error, _reason} ->
        {:ok, redirect(socket, to: "/")}
    end
  end

  def mount(_params, _session, socket) do
    {:ok, %{board: board, shapes: shapes}} = find_or_host_default_board()
    {:ok, render_board(socket, @default_board_id, board, shapes)}
  end

  defp render_board(socket, board_id, board, shapes) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(HecateWhiteboardWeb.PubSub, "board:" <> board_id)
    end

    socket
    |> assign(board_id: board_id, page_title: "hecate-whiteboard")
    |> assign(host_label: host_label())
    |> assign(stroke_count: length(shapes))
    |> assign(editing_title?: false)
    |> assign_board_status(board)
    |> push_event("shapes:snapshot", %{shapes: shapes})
  end

  @impl true
  def handle_event("stroke", %{"points" => points, "color" => color, "width" => width}, socket) do
    params = %{
      board_id: socket.assigns.board_id,
      points: points,
      color: color,
      width: width
    }

    # Hosted here: dispatch locally, same as always. Not hosted here (a
    # joined board): relay to whoever actually hosts it instead -- see
    # MaybeDrawStroke.relay/1's own doc for why this needs no reply, the
    # normal replication path brings the confirmed stroke back to us.
    if socket.assigns.hosted? do
      MaybeDrawStroke.dispatch(params)
    else
      MaybeDrawStroke.relay(params)
    end

    {:noreply, socket}
  end

  # Title is only editable by the authority for this board (can_rename?,
  # NOT the broader can_draw? -- see this module's own header). A
  # joined board's title stays plain text, no click affordance at all.
  def handle_event("edit_title", _params, %{assigns: %{can_rename?: true}} = socket),
    do: {:noreply, assign(socket, editing_title?: true)}

  def handle_event("edit_title", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_rename", _params, socket),
    do: {:noreply, assign(socket, editing_title?: false)}

  def handle_event("rename", %{"title" => title}, %{assigns: %{can_rename?: true}} = socket) do
    title = String.trim(title)

    socket =
      if title == "" do
        assign(socket, editing_title?: false)
      else
        MaybeRenameBoard.dispatch(%{board_id: socket.assigns.board_id, title: title})
        assign(socket, board_title: title, editing_title?: false)
      end

    {:noreply, socket}
  end

  def handle_event("rename", _params, socket),
    do: {:noreply, assign(socket, editing_title?: false)}

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
    hosted? = :evoq_bit_flags.has(status, BoardStatus.hosted())
    archived? = :evoq_bit_flags.has(status, BoardStatus.archived())

    assign(socket,
      board_title: board.title || "Untitled board",
      hosted?: hosted?,
      archived?: archived?,
      # Drawing works whether or not this node hosts the board (relay
      # picks up the difference); renaming stays authority-only.
      can_draw?: not archived?,
      can_rename?: hosted? and not archived?,
      status_dot: status_dot(hosted?, archived?),
      status_hint: status_hint(hosted?, archived?)
    )
  end

  defp status_dot(_hosted?, true), do: "dot-wait"
  defp status_dot(true, false), do: "dot-live"
  defp status_dot(false, false), do: "dot-relay"

  defp status_hint(_hosted?, true), do: "This board is archived. Read-only."

  defp status_hint(true, false),
    do: "This board is hosted on this node. There is no other server."

  defp status_hint(false, false),
    do: "This board is hosted elsewhere. Draws relay to the host over the mesh."

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

  defp find_or_join_board(board_id) do
    case GetBoardSnapshotById.call(board_id) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, :not_found} -> GetBoardSnapshotByIdOverMesh.call(board_id)
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
