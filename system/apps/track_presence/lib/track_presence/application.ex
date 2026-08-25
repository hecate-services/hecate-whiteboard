defmodule TrackPresence.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args), do: TrackPresence.Supervisor.start_link()
end
