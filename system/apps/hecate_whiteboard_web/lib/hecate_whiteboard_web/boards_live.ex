defmodule HecateWhiteboardWeb.BoardsLive do
  # Board picker: every board THIS node hosts (ListHostedBoards -- see
  # that module's own doc), plus a form to mint and host a brand new one,
  # plus -- fetched asynchronously so it never blocks the page -- every
  # board OTHER nodes on the mesh host (QueryBoards.ListBoardsOverMesh).
  # A board found this way opens read-only via the existing join_board
  # mechanism at /board/:board_id; this page is discovery only, it
  # doesn't grant write access to anything it didn't already have.
  use Phoenix.LiveView

  alias GuideBoardLifecycle.ArchiveBoard.MaybeArchiveBoard
  alias GuideBoardLifecycle.BoardStatus
  alias GuideBoardLifecycle.HostBoard.MaybeHostBoard
  alias GuideBoardLifecycle.InitiateBoard.MaybeInitiateBoard
  alias GuideBoardLifecycle.UnarchiveBoard.MaybeUnarchiveBoard
  alias QueryBoards.ListArchivedBoards.ListArchivedBoards
  alias QueryBoards.ListBoardsOverMesh.ListBoardsOverMesh
  alias QueryBoards.ListHostedBoards.ListHostedBoards
  alias TrackPresence.Roster

  require Logger

  # How long to wait before retrying remote-board discovery after a
  # mesh_unavailable failure -- same interval the various *Starter
  # GenServers use for their own mesh_handles() retry loop.
  @mesh_retry_ms 5_000

  # Presence is mesh-wide already -- every node absorbs every peer's
  # cursor_settled_v1 fact regardless of which node hosts that peer's
  # board (see TrackPresence.Roster's own doc), so subscribing to a
  # board's own "board:<id>" topic answers "is anyone here right now"
  # correctly from ANY node, local or remote board alike, with no new
  # mesh plumbing -- just the same topic BoardLive itself already
  # listens to. Roster now puts board_id IN the broadcast payload
  # (`{:cursor_settled, board_id, cursor}` / `{:cursor_left, board_id,
  # peer_id}`), not just the topic, specifically so a multi-board
  # subscriber like this one can tell which of its N subscriptions a
  # message came from -- BoardLive's own handlers ignore that field,
  # since it only ever subscribes to its one board and already knows.
  @impl true
  def mount(_params, _session, socket) do
    boards = ListHostedBoards.call()
    archived_boards = ListArchivedBoards.call()

    socket =
      socket
      |> assign(
        boards: boards,
        archived_boards: archived_boards,
        remote_board_facts: %{},
        remote_boards_loading?: connected?(socket),
        presence_counts: %{},
        subscribed_board_ids: MapSet.new()
      )
      |> assign(page_title: "hecate-whiteboard — boards")

    socket =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(HecateWhiteboardWeb.PubSub, "boards:remote")

        socket
        |> sync_presence_subscriptions()
        |> start_async(:discover_remote_boards, fn -> ListBoardsOverMesh.call() end)
      else
        socket
      end

    {:ok, socket}
  end

  # Seeds the accumulator from the one-shot pull query -- every board it
  # finds is, by construction, hosted somewhere (AnswerBoardListQueries
  # answers with ListHostedBoards' own output), so each one starts with
  # the hosted bit set. Live push updates (handle_info below) merge on
  # top of this, not instead of it -- pubsub never replays for a
  # subscriber that joined "boards:remote" after the fact, so without
  # this seed a tab open before a remote board existed would never learn
  # about it at all.
  @impl true
  def handle_async(:discover_remote_boards, {:ok, {:ok, found}}, socket) do
    local_ids = MapSet.new(socket.assigns.boards, & &1.board_id)

    facts =
      found
      |> Enum.reject(&MapSet.member?(local_ids, &1.board_id))
      |> Map.new(fn board ->
        {board.board_id,
         %{
           board_id: board.board_id,
           title: board.title,
           owner: board.owner,
           host: board.host,
           status: :evoq_bit_flags.set(0, BoardStatus.hosted())
         }}
      end)

    socket =
      socket
      |> assign(remote_board_facts: facts, remote_boards_loading?: false)
      |> sync_presence_subscriptions()

    {:noreply, socket}
  end

  # Unlike every other mesh integration point in this app (the various
  # *Starter GenServers), ListBoardsOverMesh.call/1 used to fail fast and
  # PERMANENTLY on mesh_unavailable -- a one-shot query with no retry of
  # its own, called exactly once at mount. A LiveView process that
  # happened to connect during the few-second window right after a node
  # restart (mesh not rejoined yet) got stuck showing "no boards found on
  # other nodes" for its entire lifetime, since nothing ever asked again.
  # Found live, right after a fleet-wide restart. Retried here rather
  # than inside ListBoardsOverMesh itself, since every other query module
  # in this app (GetBoardSnapshotByIdOverMesh included) fails fast on
  # purpose and leaves retry policy to the caller -- this keeps that
  # convention intact instead of quietly changing what `call/1` means for
  # every caller. `remote_boards_loading?` is deliberately left alone
  # here (still `true` from mount) rather than flipped to `false`: this
  # is a "still working on it," not a real failure the empty state should
  # announce.
  def handle_async(
        :discover_remote_boards,
        {:ok, {:error, {:mesh_unavailable, _} = reason}},
        socket
      ) do
    Logger.warning("[BoardsLive] discover_remote_boards: #{inspect(reason)}, retrying")
    Process.send_after(self(), :retry_discover_remote_boards, @mesh_retry_ms)
    {:noreply, socket}
  end

  def handle_async(:discover_remote_boards, {:ok, {:error, _reason}}, socket),
    do: {:noreply, assign(socket, remote_boards_loading?: false)}

  def handle_async(:discover_remote_boards, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, remote_boards_loading?: false)}

  def handle_info(:retry_discover_remote_boards, socket),
    do:
      {:noreply,
       start_async(socket, :discover_remote_boards, fn -> ListBoardsOverMesh.call() end)}

  # Live half of the same picture: GuideBoardLifecycle.BoardLifecycleV1ToMesh
  # publishes each of the five board-lifecycle events on its own topic
  # (see that module's doc for why NOT one shared topic), so
  # ProjectBoards.BoardLifecycleMeshSubscriber re-broadcasts all five
  # locally as one uniform {:remote_board_event, event_type, fact}
  # message -- this is the one place that needs to know about all five,
  # so branching on event_type here instead of at the mesh layer is the
  # right spot for it.
  #
  # A board this node hosts itself is skipped outright: its own
  # lifecycle already flows through ListHostedBoards/@boards, and
  # showing it twice (once as "here", once as "on other nodes" because
  # this node's own publish loops back through its own subscription)
  # would be visibly wrong. Four separate topics also means no ordering
  # guarantee between e.g. board_initiated_v1 and board_hosted_v1 for
  # the same board_id -- the merge below tolerates either arrival order,
  # since it only ever ORs a new status bit in and only overwrites
  # title/owner when the incoming fact actually carries one.
  @impl true
  def handle_info({:remote_board_event, event_type, fact}, socket) do
    local_ids = MapSet.new(socket.assigns.boards, & &1.board_id)
    board_id = fact.board_id

    if MapSet.member?(local_ids, board_id) do
      {:noreply, socket}
    else
      facts = merge_remote_fact(socket.assigns.remote_board_facts, board_id, event_type, fact)

      socket =
        socket
        |> assign(remote_board_facts: facts)
        |> sync_presence_subscriptions()

      {:noreply, socket}
    end
  end

  # ProjectBoards.BoardLifecycleToBoards broadcasts this on "board:<id>"
  # AFTER it writes the ETS row -- this LiveView already subscribes to
  # every locally-hosted board_id's own topic via
  # sync_presence_subscriptions/1 (for presence), so archive/unarchive/
  # rename land here for free. Re-deriving BOTH lists from the read model
  # rather than patching the one board_id in place: whether an update
  # belongs in @boards or @archived_boards depends on the SAME status
  # bits ListHostedBoards/ListArchivedBoards already interpret, so
  # re-running those two cheap ETS scans is simpler and can't drift from
  # what a fresh page load would show. This is also WHY
  # handle_event("archive"/"unarchive", ...) doesn't refetch immediately
  # after dispatch: the command's own {:ok, ...} return only confirms the
  # EVENT was written, not that this handler has already run against it,
  # so re-querying right there raced the projection and showed stale
  # state -- confirmed live, the button worked but the board never
  # visibly moved lists until now.
  @impl true
  def handle_info({:board_updated, _updated}, socket) do
    socket =
      socket
      |> assign(boards: ListHostedBoards.call(), archived_boards: ListArchivedBoards.call())
      |> sync_presence_subscriptions()

    {:noreply, socket}
  end

  # Recomputes only the one board_id the event is actually about --
  # cheap (a single ETS match) and can't drift, since it's driven by
  # the exact same touch/remove that updated Roster's own table.
  def handle_info({:cursor_settled, board_id, _cursor}, socket),
    do: {:noreply, refresh_presence_count(socket, board_id)}

  def handle_info({:cursor_left, board_id, _peer_id}, socket),
    do: {:noreply, refresh_presence_count(socket, board_id)}

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp refresh_presence_count(socket, board_id) do
    count = board_id |> Roster.list_for_board() |> length()
    assign(socket, presence_counts: Map.put(socket.assigns.presence_counts, board_id, count))
  end

  # Diffs the currently-listed board_ids (local + remote) against what
  # this process is already subscribed to, subscribing to newly-seen
  # ones and unsubscribing from ones that dropped out (an archived
  # remote board, mainly) -- called after every state change that can
  # grow or shrink that set, instead of fixing the subscription set
  # once at mount. Also (re)seeds presence_counts for every currently
  # known board_id, so a board that already had peers on it when
  # discovered shows the right count immediately, not just after its
  # next cursor event.
  defp sync_presence_subscriptions(socket) do
    current_ids =
      MapSet.new(
        Enum.map(socket.assigns.boards, & &1.board_id) ++
          Enum.map(socket.assigns.archived_boards, & &1.board_id) ++
          Map.keys(socket.assigns.remote_board_facts)
      )

    previous_ids = socket.assigns.subscribed_board_ids

    Enum.each(MapSet.difference(current_ids, previous_ids), fn board_id ->
      Phoenix.PubSub.subscribe(HecateWhiteboardWeb.PubSub, "board:" <> board_id)
    end)

    Enum.each(MapSet.difference(previous_ids, current_ids), fn board_id ->
      Phoenix.PubSub.unsubscribe(HecateWhiteboardWeb.PubSub, "board:" <> board_id)
    end)

    counts =
      Map.new(current_ids, fn board_id -> {board_id, length(Roster.list_for_board(board_id))} end)

    assign(socket, subscribed_board_ids: current_ids, presence_counts: counts)
  end

  @impl true
  def handle_event("create", %{"title" => title}, socket) do
    title = title |> String.trim() |> default_title()

    case create_board(title) do
      {:ok, board_id} ->
        {:noreply, push_navigate(socket, to: "/board/#{board_id}")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Couldn't create that board. Try again.")
         |> assign(boards: ListHostedBoards.call())}
    end
  end

  # Archive/unarchive are host-only actions -- MaybeArchiveBoard/
  # MaybeUnarchiveBoard have no relay/1 (unlike the shape-mutation desks),
  # matching that this button only ever renders on a board THIS node
  # hosts (see the template: the "hosted here" list, never "on other
  # nodes"). Deliberately does NOT assign boards/archived_boards here on
  # success -- see handle_info({:board_updated, ...}) above for why an
  # eager re-query at this exact point reads the projection before it's
  # caught up. This LiveView is already subscribed to this board_id's
  # topic (sync_presence_subscriptions/1), so the broadcast that
  # handler reacts to arrives within the same round trip in practice.
  @impl true
  def handle_event("archive", %{"board_id" => board_id}, socket) do
    case MaybeArchiveBoard.dispatch(%{board_id: board_id}) do
      {:ok, _version, _events} ->
        {:noreply, socket}

      {:error, reason} ->
        Logger.warning("[BoardsLive] archive #{board_id}: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, "Couldn't archive that board.")}
    end
  end

  def handle_event("unarchive", %{"board_id" => board_id}, socket) do
    case MaybeUnarchiveBoard.dispatch(%{board_id: board_id}) do
      {:ok, _version, _events} ->
        {:noreply, socket}

      {:error, reason} ->
        Logger.warning("[BoardsLive] unarchive #{board_id}: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, "Couldn't unarchive that board.")}
    end
  end

  defp default_title(""), do: "Untitled board"
  defp default_title(title), do: title

  defp create_board(title) do
    with {:ok, board_id, _version, _events} <-
           MaybeInitiateBoard.dispatch(%{owner: host_label(), title: title}),
         {:ok, _version, _events} <- MaybeHostBoard.dispatch(%{board_id: board_id}) do
      {:ok, board_id}
    end
  end

  defp host_label do
    case Node.self() do
      :nonode@nohost -> "local"
      node -> node |> Atom.to_string() |> String.split("@") |> List.last()
    end
  end

  # An archived remote board now just carries the archived bit, same as
  # every other status transition -- kept in the map rather than deleted
  # (the ORIGINAL reasoning here, "once gone it's gone, no un-archiving
  # path to reconcile against later," stopped being true the moment
  # unarchive_board existed: deleting on archive would have silently lost
  # title/owner/host, so a later board_unarchived_v1 fact would have
  # nothing to merge onto and reappeared blank). remote_boards/1 below is
  # the one place that filters archived ones out of the rendered list,
  # matching ListHostedBoards' own "hosted AND NOT archived" filter for
  # the LOCAL list -- filtering at render time (not accumulation time)
  # means an unarchive fact correctly makes the board reappear with its
  # full info intact, not a blank slot.
  defp merge_remote_fact(facts, board_id, event_type, fact) do
    existing =
      Map.get(facts, board_id, %{board_id: board_id, title: nil, owner: nil, host: nil, status: 0})

    updated = %{
      existing
      | title: fact[:title] || existing.title,
        owner: fact[:owner] || existing.owner,
        host: fact[:host] || existing.host,
        status: apply_status_bit(existing.status, event_type)
    }

    Map.put(facts, board_id, updated)
  end

  defp apply_status_bit(status, "board_initiated_v1"),
    do: :evoq_bit_flags.set(status, BoardStatus.initiated())

  defp apply_status_bit(status, "board_hosted_v1"),
    do: :evoq_bit_flags.set(status, BoardStatus.hosted())

  defp apply_status_bit(status, "board_archived_v1"),
    do: :evoq_bit_flags.set(status, BoardStatus.archived())

  defp apply_status_bit(status, "board_unarchived_v1"),
    do: :evoq_bit_flags.unset(status, BoardStatus.archived())

  defp apply_status_bit(status, "board_renamed_v1"), do: status

  # Template-facing view of the accumulator: sorted, and a nil title
  # (a hosted/renamed fact can arrive before the initiated fact that
  # carries the actual title -- see the ordering note above) falls back
  # to the board_id rather than rendering blank.
  def remote_boards(remote_board_facts) do
    remote_board_facts
    |> Map.values()
    |> Enum.reject(&archived?(&1.status))
    |> Enum.map(fn board -> Map.update!(board, :title, &(&1 || board.board_id)) end)
    |> Enum.sort_by(& &1.title)
  end

  def hosted?(status), do: :evoq_bit_flags.has(status, BoardStatus.hosted())
  def archived?(status), do: :evoq_bit_flags.has(status, BoardStatus.archived())

  def presence_label(1), do: "1 here"
  def presence_label(n), do: "#{n} here"
end
