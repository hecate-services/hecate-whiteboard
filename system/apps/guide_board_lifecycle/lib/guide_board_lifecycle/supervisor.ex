defmodule GuideBoardLifecycle.Supervisor do
  # Supervises this CMD department's own processes -- currently none.
  # No aggregate children here: evoq's own aggregate registry starts
  # BoardAggregate processes on demand, keyed by stream id, the first time
  # a command dispatches against them. Later phases add mesh-facing policy
  # children here (mirroring hecate-tube's guide_tube_lifecycle_sup) once
  # host_board/draw_stroke exist to publish anything.
  @moduledoc false

  use Supervisor

  def start_link, do: Supervisor.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init([]), do: Supervisor.init([], strategy: :one_for_one)
end
