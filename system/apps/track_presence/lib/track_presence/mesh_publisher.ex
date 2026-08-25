defmodule TrackPresence.MeshPublisher do
  # Trivial fire-and-forget :macula_publisher callback, mirrors
  # GuideBoardLifecycle.MeshPublisher exactly -- each app that publishes
  # keeps its own copy rather than reaching across the umbrella for one.
  @behaviour :macula_publisher

  @impl true
  def init(_args), do: {:ok, nil}

  @impl true
  def handle_published(result, state) do
    require Logger
    Logger.debug("[TrackPresence.MeshPublisher] outcome: #{inspect(result)}")
    {:stop, :normal, state}
  end
end
