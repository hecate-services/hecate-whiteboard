defmodule TrackPresence.Sweep do
  # Periodic timer that ages out stale roster rows -- see Roster.sweep/1
  # for the actual staleness check and why this needs no cross-node
  # coordination. Runs well below Roster.stale_after_ms so a genuinely
  # gone peer's cursor doesn't linger past its own staleness window by
  # more than one tick.
  use GenServer

  alias TrackPresence.Roster

  @interval_ms 5_000

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init([]) do
    :timer.send_interval(@interval_ms, :sweep)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    Roster.sweep()
    {:noreply, state}
  end
end
