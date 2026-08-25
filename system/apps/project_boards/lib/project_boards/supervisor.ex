defmodule ProjectBoards.Supervisor do
  # Owns the ETS store's lifetime, then the projections that write to it.
  # evoq_event_handler:start_link/3 is the generic supervised wrapper both
  # projections and process managers use (confirmed against hecate-tube's
  # own guide_tube_lifecycle_sup, not the evoq_projection facade -- that
  # module's own start_link/3 was never exercised, only documented).
  @moduledoc false

  use Supervisor

  alias ProjectBoards.BoardLifecycleToBoards.BoardLifecycleToBoards
  alias ProjectBoards.StrokeDrawnV1ToBoardShapes.StrokeDrawnV1ToBoardShapes

  def start_link, do: Supervisor.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init([]) do
    children = [
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
