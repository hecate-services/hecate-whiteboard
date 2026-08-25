defmodule ProjectBoards.Supervisor do
  # Owns the ETS store's lifetime, then the projections that write to it.
  # evoq_event_handler:start_link/3 is the generic supervised wrapper both
  # projections and process managers use (confirmed against hecate-tube's
  # own guide_tube_lifecycle_sup, not the evoq_projection facade -- that
  # module's own start_link/3 was never exercised, only documented).
  #
  # ALSO starts HecateWhiteboardWeb.PubSub, even though the name says
  # "web" and this is the PRJ app -- deliberate, not a leftover. The
  # umbrella's REAL application boot order (computed from actual mix.exs
  # deps, not whatever order releases() lists them in) has
  # hecate_whiteboard_web depend on query_boards, which depends on this
  # app -- so project_boards ALWAYS starts before hecate_whiteboard_web,
  # never after. Starting the shared PubSub registry there instead (as
  # this app's own first child, before anything that broadcasts to it)
  # crashed for real at cold boot: a mesh event arriving in the split
  # second after BoardMeshSubscriberStarter subscribes, but before
  # hecate_whiteboard_web has started, hit `unknown registry:
  # HecateWhiteboardWeb.PubSub` inside Phoenix.PubSub.broadcast/3 and
  # dropped that stroke. The writer side owning the registry makes the
  # race impossible by construction rather than by hoping boot is fast.
  @moduledoc false

  use Supervisor

  alias ProjectBoards.BoardLifecycleToBoards.BoardLifecycleToBoards
  alias ProjectBoards.StrokeDrawnV1ToBoardShapes.StrokeDrawnV1ToBoardShapes

  def start_link, do: Supervisor.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init([]) do
    children = [
      {Phoenix.PubSub, name: HecateWhiteboardWeb.PubSub},
      ProjectBoards.Store,
      handler(BoardLifecycleToBoards),
      handler(StrokeDrawnV1ToBoardShapes),
      {DynamicSupervisor, name: ProjectBoards.MeshSubscriberSupervisor, strategy: :one_for_one},
      ProjectBoards.BoardMeshSubscriberStarter
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp handler(module) do
    %{
      id: module,
      start: {:evoq_event_handler, :start_link, [module, %{}, %{}]},
      restart: :permanent,
      shutdown: 5_000,
      type: :worker,
      modules: [module]
    }
  end
end
