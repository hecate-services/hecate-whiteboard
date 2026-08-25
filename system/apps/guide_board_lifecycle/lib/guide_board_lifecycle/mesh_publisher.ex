defmodule GuideBoardLifecycle.MeshPublisher do
  # Trivial fire-and-forget :macula_publisher callback shared by every
  # mesh-fact emitter in this app -- none of them need to react to the
  # publish outcome, they just want the supervised pid/mesh-fact
  # machinery macula_publisher already provides around a bare
  # macula:publish/4. Mirrors hecate-tube's tube_mesh_publisher.erl.
  @behaviour :macula_publisher

  @impl true
  def init(_args), do: {:ok, nil}

  @impl true
  def handle_published(result, state) do
    require Logger
    Logger.info("[MeshPublisher] outcome: #{inspect(result)}")
    {:stop, :normal, state}
  end
end
