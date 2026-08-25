defmodule HecateWhiteboardWeb.BoardsLive do
  # Board picker: every board THIS node hosts (ListHostedBoards -- see
  # that module's own doc), plus a form to mint and host a brand new one,
  # plus -- fetched asynchronously so it never blocks the page -- every
  # board OTHER nodes on the mesh host (QueryBoards.ListBoardsOverMesh).
  # A board found this way opens read-only via the existing join_board
  # mechanism at /board/:board_id; this page is discovery only, it
  # doesn't grant write access to anything it didn't already have.
  use Phoenix.LiveView

  alias GuideBoardLifecycle.HostBoard.MaybeHostBoard
  alias GuideBoardLifecycle.InitiateBoard.MaybeInitiateBoard
  alias QueryBoards.ListBoardsOverMesh.ListBoardsOverMesh
  alias QueryBoards.ListHostedBoards.ListHostedBoards

  @impl true
  def mount(_params, _session, socket) do
    boards = ListHostedBoards.call()

    socket =
      socket
      |> assign(boards: boards, remote_boards: [], remote_boards_loading?: connected?(socket))
      |> assign(page_title: "hecate-whiteboard — boards")

    socket =
      if connected?(socket) do
        start_async(socket, :discover_remote_boards, fn -> ListBoardsOverMesh.call() end)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_async(:discover_remote_boards, {:ok, {:ok, found}}, socket) do
    local_ids = MapSet.new(socket.assigns.boards, & &1.board_id)
    remote = Enum.reject(found, &MapSet.member?(local_ids, &1.board_id))
    {:noreply, assign(socket, remote_boards: remote, remote_boards_loading?: false)}
  end

  def handle_async(:discover_remote_boards, {:ok, {:error, _reason}}, socket),
    do: {:noreply, assign(socket, remote_boards_loading?: false)}

  def handle_async(:discover_remote_boards, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, remote_boards_loading?: false)}

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
end
