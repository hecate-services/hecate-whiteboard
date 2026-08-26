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
  alias GuideBoardLifecycle.DrawGeometry.MaybeDrawGeometry
  alias GuideBoardLifecycle.DrawStroke.MaybeDrawStroke
  alias GuideBoardLifecycle.HostBoard.MaybeHostBoard
  alias GuideBoardLifecycle.LeaveBoard.MaybeLeaveBoard
  alias GuideBoardLifecycle.MoveShape.MaybeMoveShape
  alias GuideBoardLifecycle.PlaceSticky.MaybePlaceSticky
  alias GuideBoardLifecycle.PlaceText.MaybePlaceText
  alias GuideBoardLifecycle.RemoveShape.MaybeRemoveShape
  alias GuideBoardLifecycle.RenameBoard.MaybeRenameBoard
  alias QueryBoards.GetBoardSnapshotById.GetBoardSnapshotById
  alias QueryBoards.GetBoardSnapshotByIdOverMesh.GetBoardSnapshotByIdOverMesh
  alias TrackPresence.Roster

  # One default board per node for this walking-skeleton phase -- board
  # creation UX (multiple boards, a picker) is out of scope here; this
  # proves host_board -> draw_stroke -> the browser, not board management.
  #
  # Derived from this node's own identity (Node.self()) rather than one
  # literal shared across the whole fleet -- a single hardcoded id here
  # meant every node that couldn't reach the real host over the mesh in
  # time (find_or_host_default_board/0's :not_found fallback) silently
  # minted its OWN independent board under the SAME id, so beam01, beam02
  # and msi00 ended up with three different boards answering to one
  # board_id (found live 2026-08-26, see CHANGELOG). Node.self() is fixed
  # per deployed node (distinct hecate_whiteboard@<host> per fleet box,
  # :nonode@nohost for local dev), so this is still stable across restarts
  # -- it just no longer collides across nodes.
  #
  # MUST be a real reckon_gater_stream_id shape (<prefix>-<32 hex>), not a
  # human-readable literal -- "board-default" hit exactly the antipattern
  # documented in this repo's own plan doc ({:invalid_stream_id, ...},
  # reckon_db_stream_path:id_nodes/1 crash-looping the store's gateway
  # worker on every read). Hashing Node.self() with md5 always yields 32
  # hex chars, satisfying that shape without needing to mint+hardcode one
  # per box by hand.
  defp default_board_id do
    "board-" <>
      (Node.self()
       |> Atom.to_string()
       |> then(&:crypto.hash(:md5, &1))
       |> Base.encode16(case: :lower))
  end

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
    {:ok, render_board(socket, default_board_id(), board, shapes)}
  end

  defp render_board(socket, board_id, board, shapes) do
    peer_id = new_peer_id()
    peer_color = presence_color(peer_id)
    label = host_label()

    # Registers presence at CONNECT time, not at first cursor movement --
    # BoardsLive's "N here" picker badge counts Roster.list_for_board/1,
    # and until this call existed that table only ever gained a row once
    # this peer's JS hook had debounced a real pointer stop (see
    # Roster.touch/1's own doc). A viewer who opens a board and doesn't
    # move their mouse was invisible to the picker the whole time they
    # were actually there -- found live ("the number of participants in
    # /boards is not correct"). x/y are nil here on purpose: no real
    # cursor position exists yet, and the two call sites below (the
    # snapshot filter and the cursor_settled handler) both know to treat
    # a nil-x row as "present, not yet positioned" rather than rendering
    # a phantom marker at a NaN screen position for other viewers.
    #
    # Guarded on connected?(socket) for the same reason terminate/2 is:
    # the disconnected static-render pass runs this function too, with a
    # peer_id that gets thrown away and replaced the instant the socket
    # actually connects -- registering it would leave an ownerless row
    # terminate/2 can never clean up (it also guards on connected?/1).
    if connected?(socket) do
      Phoenix.PubSub.subscribe(HecateWhiteboardWeb.PubSub, "board:" <> board_id)

      Roster.touch(%{
        board_id: board_id,
        peer_id: peer_id,
        x: nil,
        y: nil,
        color: peer_color,
        label: label
      })
    end

    socket =
      socket
      |> assign(board_id: board_id, page_title: "hecate-whiteboard")
      |> assign(host_label: label)
      |> assign(peer_id: peer_id, peer_color: peer_color, peer_label: label)
      |> assign(stroke_count: length(shapes))
      |> assign(editing_title?: false)
      |> assign_board_status(board)
      |> push_event("shapes:snapshot", %{shapes: shapes})

    # Late-join snapshot for presence, same idea as shapes:snapshot above:
    # a joining viewer sees everyone already-settled immediately, rather
    # than waiting for each of their next pointer pause. Excludes this
    # peer's own row, and excludes anyone else's nil-x join-only row too
    # (nothing to draw yet for a peer who hasn't moved their mouse
    # either) -- same reasoning as the cursor_settled handler below.
    cursors =
      board_id
      |> Roster.list_for_board()
      |> Enum.reject(&(&1.peer_id == peer_id or is_nil(&1.x)))

    push_event(socket, "cursor:snapshot", %{cursors: cursors})
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

  # Sticky/text/move/remove all follow the exact same hosted?/relay split
  # as "stroke" above -- see MaybePlaceSticky.relay/1's own doc for why
  # these four share ONE relay-request topic instead of draw_stroke's
  # per-command one.
  def handle_event(
        "place_sticky",
        %{"x" => x, "y" => y, "color" => color, "text" => text},
        socket
      ) do
    params = %{board_id: socket.assigns.board_id, x: x, y: y, color: color, text: text}

    if socket.assigns.hosted?,
      do: MaybePlaceSticky.dispatch(params),
      else: MaybePlaceSticky.relay(params)

    {:noreply, socket}
  end

  def handle_event("place_text", %{"x" => x, "y" => y, "color" => color, "text" => text}, socket) do
    params = %{board_id: socket.assigns.board_id, x: x, y: y, color: color, text: text}

    if socket.assigns.hosted?,
      do: MaybePlaceText.dispatch(params),
      else: MaybePlaceText.relay(params)

    {:noreply, socket}
  end

  def handle_event("move_shape", %{"shape_id" => shape_id, "points" => points}, socket) do
    params = %{board_id: socket.assigns.board_id, shape_id: shape_id, points: points}

    if socket.assigns.hosted?,
      do: MaybeMoveShape.dispatch(params),
      else: MaybeMoveShape.relay(params)

    {:noreply, socket}
  end

  def handle_event("remove_shape", %{"shape_id" => shape_id}, socket) do
    params = %{board_id: socket.assigns.board_id, shape_id: shape_id}

    if socket.assigns.hosted?,
      do: MaybeRemoveShape.dispatch(params),
      else: MaybeRemoveShape.relay(params)

    {:noreply, socket}
  end

  def handle_event(
        "draw_geometry",
        %{"kind" => kind, "points" => points, "color" => color} = raw_params,
        socket
      ) do
    params = %{
      board_id: socket.assigns.board_id,
      kind: kind,
      points: points,
      color: color,
      from_shape_id: Map.get(raw_params, "from_shape_id"),
      to_shape_id: Map.get(raw_params, "to_shape_id")
    }

    if socket.assigns.hosted?,
      do: MaybeDrawGeometry.dispatch(params),
      else: MaybeDrawGeometry.relay(params)

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

  # Sent by the JS hook only after ~400ms of no pointer movement (see
  # board_canvas_hook.js) -- this handler never sees raw high-frequency
  # movement, so no server-side throttling is needed on top of the
  # client's own debounce. Fires regardless of can_draw? -- a view-only
  # peer's cursor is still worth showing to collaborators.
  def handle_event("cursor:settle", %{"x" => x, "y" => y}, socket) do
    Roster.touch(%{
      board_id: socket.assigns.board_id,
      peer_id: socket.assigns.peer_id,
      x: x,
      y: y,
      color: socket.assigns.peer_color,
      label: socket.assigns.peer_label
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

  def handle_info({:shape_placed, shape}, socket),
    do: {:noreply, push_event(socket, "shape_placed", shape)}

  def handle_info({:shape_moved, payload}, socket),
    do: {:noreply, push_event(socket, "shape_moved", payload)}

  def handle_info({:shape_removed, shape_id}, socket),
    do: {:noreply, push_event(socket, "shape_removed", %{shape_id: shape_id})}

  # Never echo a peer's own settled/left cursor back to itself -- this
  # process is both the origin and, via the same board:<id> PubSub topic
  # every viewer subscribes to, a recipient of its own broadcast.
  #
  # board_id in the payload (not just the topic) is for BoardsLive's
  # benefit, which watches many boards' topics from one process and
  # needs it to disambiguate -- this module only ever subscribes to its
  # own board_id, so it's always redundant here, hence the `_`.
  def handle_info(
        {:cursor_settled, _board_id, %{peer_id: peer_id}},
        %{assigns: %{peer_id: peer_id}} = s
      ),
      do: {:noreply, s}

  # A join-time registration (Roster.touch/1 called from mount, before
  # any real pointer movement) carries x: nil -- nothing to render for
  # other viewers until the first real cursor:settle updates it. Without
  # this clause, every viewer's mount would flash a marker at a NaN
  # screen position on every other connected peer's canvas.
  def handle_info({:cursor_settled, _board_id, %{x: nil}}, socket), do: {:noreply, socket}

  def handle_info({:cursor_settled, _board_id, cursor}, socket),
    do: {:noreply, push_event(socket, "cursor:update", cursor)}

  def handle_info({:cursor_left, _board_id, peer_id}, %{assigns: %{peer_id: peer_id}} = socket),
    do: {:noreply, socket}

  def handle_info({:cursor_left, _board_id, peer_id}, socket),
    do: {:noreply, push_event(socket, "cursor:remove", %{peer_id: peer_id})}

  # Graceful exit only -- guarded on connected?(socket) because terminate/2
  # also fires for the disconnected static-render pass every mount does
  # first (see render_board), which never touched the roster or dispatched
  # anything presence-related in the first place. An UNgraceful exit
  # (network drop, browser crash) never reaches this at all; Roster.sweep/1
  # is what ages those out, deliberately without an event-store write --
  # see plans/PLAN_HECATE_WHITEBOARD_ROOT.md's "Presence is not
  # event-sourced" decision for why that split is intentional.
  @impl true
  def terminate(_reason, socket) do
    if connected?(socket) do
      board_id = socket.assigns.board_id
      peer_id = socket.assigns.peer_id
      params = %{board_id: board_id, peer_id: peer_id}

      Roster.remove(board_id, peer_id)

      if socket.assigns.hosted? do
        MaybeLeaveBoard.dispatch(params)
      else
        MaybeLeaveBoard.relay(params)
      end
    end

    :ok
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
    case GetBoardSnapshotById.call(default_board_id()) do
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
      MaybeHostBoard.dispatch(%{board_id: default_board_id()})
      %{board | status: :evoq_bit_flags.set(board.status, BoardStatus.hosted())}
    end
  end

  # The default board's id is fixed per node (derived, not minted), so it
  # survives a process restart -- deliberate exception to InitiateBoardV1
  # normally minting one, since there's exactly one default board per node
  # in this phase. Dispatched via the raw evoq primitives rather than
  # MaybeInitiateBoard.dispatch/1, which always mints a fresh id and has no
  # way to accept a caller-supplied one.
  defp initiate_default_board do
    id = default_board_id()
    board = %{board_id: id, owner: "host", title: "Untitled board"}
    # BoardAggregate.execute/2 pattern-matches on command_type -- forgetting
    # it here (leaving the aggregate-facing payload identical to the
    # returned board shape) is exactly the kind of skew this file's own
    # `find_or_host_default_board` doc comment exists to avoid re-deriving.
    command_payload = Map.put(board, :command_type, :initiate_board)

    :evoq_router.dispatch(
      :evoq_command.new(
        :initiate_board,
        GuideBoardLifecycle.BoardAggregate,
        id,
        command_payload
      )
    )

    Map.put(board, :status, :evoq_bit_flags.set(0, BoardStatus.initiated()))
  end

  # Fresh per LiveView mount, not tied to any account -- presence is
  # anonymous ephemeral session state (see TrackPresence.Roster's own
  # header), a browser refresh is simply a new peer as far as the roster
  # is concerned. This is also what makes a replayed peer_departed_v1
  # from evoq's catchup-on-restart harmless: a reconnecting peer always
  # gets a NEW peer_id, so a stale departure can never collide with a
  # live one -- see PeerDepartedV1ToMesh's own comment.
  defp new_peer_id, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  # Deterministic hash -> HSL so the same peer_id always renders the same
  # color for the lifetime of one session, with no accounts/auth
  # involved. Fixed saturation/lightness keeps every color readable
  # against the chalk-on-slate canvas regardless of hue.
  defp presence_color(peer_id) do
    <<hue::16, _rest::binary>> = :crypto.hash(:md5, peer_id)
    "hsl(#{rem(hue, 360)}, 70%, 65%)"
  end

  defp host_label do
    host =
      case Node.self() do
        :nonode@nohost -> "local"
        node -> node |> Atom.to_string() |> String.split("@") |> List.last() |> host_short()
      end

    case station_label() do
      nil -> host
      station -> host <> " via " <> station
    end
  end

  # "beam01.lab" -> "beam01" -- the ".lab" suffix is implied by the demo
  # fleet's own naming, dropping it keeps the topbar from repeating what
  # "via {station}" already makes clear is a machine, not a domain.
  defp host_short(host), do: host |> String.split(".") |> List.first()

  # "https://station-de-falkenstein.macula.io:4433" -> "de-falkenstein".
  # MACULA_STATION_SEEDS is a single URL for this app (no comma-separated
  # fallback list like hecate-dronex uses), so the first match is the
  # only one there is.
  defp station_label do
    case System.get_env("MACULA_STATION_SEEDS") do
      nil ->
        nil

      seeds ->
        case Regex.run(~r/station-([a-z0-9-]+)\.macula\.io/, seeds) do
          [_, name] -> name
          nil -> nil
        end
    end
  end
end
