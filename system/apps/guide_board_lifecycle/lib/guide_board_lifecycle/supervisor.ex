defmodule GuideBoardLifecycle.Supervisor do
  # Supervises this CMD department's own processes: the mesh-facing PMs
  # that react to this app's own domain events by publishing to the mesh
  # (mirrors hecate-tube's guide_tube_lifecycle_sup), plus
  # AnswerDrawStrokeRequestsStarter -- the write-relay's inbound
  # subscriber, letting a joining peer draw on a board this node
  # actually hosts. No aggregate children here: evoq's own aggregate
  # registry starts BoardAggregate processes on demand, keyed by stream
  # id, the first time a command dispatches against them.
  @moduledoc false

  use Supervisor

  alias GuideBoardLifecycle.DrawStroke.AnswerDrawStrokeRequestsStarter
  alias GuideBoardLifecycle.LeaveBoard.AnswerLeaveBoardRequestsStarter
  alias GuideBoardLifecycle.LeaveBoard.PeerDepartedV1ToMesh
  alias GuideBoardLifecycle.StrokeDrawnV1ToMesh.StrokeDrawnV1ToMesh

  def start_link, do: Supervisor.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init([]) do
    children = [
      handler(StrokeDrawnV1ToMesh),
      handler(PeerDepartedV1ToMesh),
      {DynamicSupervisor,
       name: GuideBoardLifecycle.MeshSubscriberSupervisor, strategy: :one_for_one},
      AnswerDrawStrokeRequestsStarter,
      AnswerLeaveBoardRequestsStarter
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
