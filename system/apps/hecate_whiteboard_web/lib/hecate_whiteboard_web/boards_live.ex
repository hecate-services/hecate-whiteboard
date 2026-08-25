defmodule HecateWhiteboardWeb.BoardsLive do
  # Board picker: every board THIS node hosts (ListHostedBoards -- see
  # that module's own doc for why it's scoped to hosted-here, not every
  # board_id this node happens to have cached from a past join), plus a
  # form to mint and host a brand new one. A board someone else hosts is
  # still reachable directly at /board/:board_id if you have the id --
  # this page only solves "what can I open without already knowing an
  # id," not board discovery across the mesh.
  use Phoenix.LiveView

  alias GuideBoardLifecycle.HostBoard.MaybeHostBoard
  alias GuideBoardLifecycle.InitiateBoard.MaybeInitiateBoard
  alias QueryBoards.ListHostedBoards.ListHostedBoards

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket, boards: ListHostedBoards.call(), page_title: "hecate-whiteboard — boards")}
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
