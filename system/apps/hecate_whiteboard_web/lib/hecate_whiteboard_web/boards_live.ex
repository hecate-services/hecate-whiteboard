defmodule HecateWhiteboardWeb.BoardsLive do
  # Board picker: every board THIS node hosts (ListHostedBoards -- see
  # that module's own doc), plus a form to mint and host a brand new one,
  # plus -- fetched asynchronously so it never blocks the page -- every
  # board OTHER nodes on the mesh host (QueryBoards.ListBoardsOverMesh).
  # A board found this way opens read-only via the existing join_board
  # mechanism at /board/:board_id; this page is discovery only, it
  # doesn't grant write access to anything it didn't already have.
  use Phoenix.LiveView

  alias GuideBoardLifecycle.BoardStatus
  alias GuideBoardLifecycle.HostBoard.MaybeHostBoard
  alias GuideBoardLifecycle.InitiateBoard.MaybeInitiateBoard
  alias QueryBoards.ListBoardsOverMesh.ListBoardsOverMesh
  alias QueryBoards.ListHostedBoards.ListHostedBoards

  @impl true
  def mount(_params, _session, socket) do
    boards = ListHostedBoards.call()

    socket =
      socket
      |> assign(
        boards: boards,
        remote_board_facts: %{},
        remote_boards_loading?: connected?(socket)
      )
      |> assign(page_title: "hecate-whiteboard — boards")

    socket =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(HecateWhiteboardWeb.PubSub, "boards:remote")
        start_async(socket, :discover_remote_boards, fn -> ListBoardsOverMesh.call() end)
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

    {:noreply, assign(socket, remote_board_facts: facts, remote_boards_loading?: false)}
  end

  def handle_async(:discover_remote_boards, {:ok, {:error, _reason}}, socket),
    do: {:noreply, assign(socket, remote_boards_loading?: false)}

  def handle_async(:discover_remote_boards, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, remote_boards_loading?: false)}

  # Live half of the same picture: GuideBoardLifecycle.BoardLifecycleV1ToMesh
  # publishes each of the four board-lifecycle events on its own topic
  # (see that module's doc for why NOT one shared topic), so
  # ProjectBoards.BoardLifecycleMeshSubscriber re-broadcasts all four
  # locally as one uniform {:remote_board_event, event_type, fact}
  # message -- this is the one place that needs to know about all four,
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
      {:noreply, assign(socket, remote_board_facts: facts)}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

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

  # An archived remote board drops out entirely, mirroring
  # QueryBoards.ListHostedBoards' own "hosted AND NOT archived" filter --
  # once gone it's gone, there's no un-archiving path to reconcile
  # against later.
  defp merge_remote_fact(facts, board_id, "board_archived_v1", _fact),
    do: Map.delete(facts, board_id)

  defp merge_remote_fact(facts, board_id, event_type, fact) do
    existing =
      Map.get(facts, board_id, %{board_id: board_id, title: nil, owner: nil, host: nil, status: 0})

    updated = %{
      existing
      | title: fact[:title] || existing.title,
        owner: fact[:owner] || existing.owner,
        host: fact[:host] || existing.host,
        status: :evoq_bit_flags.set(existing.status, status_bit(event_type))
    }

    Map.put(facts, board_id, updated)
  end

  defp status_bit("board_initiated_v1"), do: BoardStatus.initiated()
  defp status_bit("board_hosted_v1"), do: BoardStatus.hosted()
  defp status_bit("board_renamed_v1"), do: 0

  # Template-facing view of the accumulator: sorted, and a nil title
  # (a hosted/renamed fact can arrive before the initiated fact that
  # carries the actual title -- see the ordering note above) falls back
  # to the board_id rather than rendering blank.
  def remote_boards(remote_board_facts) do
    remote_board_facts
    |> Map.values()
    |> Enum.map(fn board -> Map.update!(board, :title, &(&1 || board.board_id)) end)
    |> Enum.sort_by(& &1.title)
  end

  def hosted?(status), do: :evoq_bit_flags.has(status, BoardStatus.hosted())
end
