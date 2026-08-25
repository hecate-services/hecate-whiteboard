defmodule QueryBoards.MeshPublisher do
  # Trivial fire-and-forget :macula_publisher callback, mirrors
  # GuideBoardLifecycle.MeshPublisher -- duplicated rather than shared
  # across apps, since a QRY app pulling in a CMD app's publisher just to
  # reuse ten lines would be a worse coupling than the duplication.
  # Used by both halves of join_board's mesh query: the client-side query
  # publish and the host-side snapshot-reply publish.
  @behaviour :macula_publisher

  @impl true
  def init(_args), do: {:ok, nil}

  @impl true
  def handle_published(result, state) do
    require Logger
    Logger.info("[QueryBoards.MeshPublisher] outcome: #{inspect(result)}")
    {:stop, :normal, state}
  end
end
