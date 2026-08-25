defmodule TrackPresence.Supervisor do
  # Owns the roster's lifetime, the sweep timer, and both inbound mesh
  # subscribers -- mirrors ProjectBoards.Supervisor's shape (store first,
  # then everything that reads/writes it). Does NOT start
  # HecateWhiteboardWeb.PubSub itself -- project_boards' own Supervisor
  # already does, and this app's mix.exs dependency on project_boards
  # guarantees it starts first (see that dep's own comment).
  @moduledoc false

  use Supervisor

  def start_link, do: Supervisor.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init([]) do
    children = [
      TrackPresence.Roster,
      TrackPresence.Sweep,
      {DynamicSupervisor, name: TrackPresence.MeshSubscriberSupervisor, strategy: :one_for_one},
      TrackPresence.CursorMeshSubscriberStarter,
      TrackPresence.PeerDepartedMeshSubscriberStarter
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
