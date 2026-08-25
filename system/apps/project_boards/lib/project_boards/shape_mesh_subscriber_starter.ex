defmodule ProjectBoards.ShapeMeshSubscriberStarter do
  # Starts ShapeMeshSubscriber once the shared mesh pool is up, then stops
  # retrying -- mirrors ProjectBoards.BoardMeshSubscriberStarter exactly.
  use GenServer
  require Logger

  @retry_ms 5_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    send(self(), :start_subscriber)
    {:ok, %{started: false}}
  end

  @impl true
  def handle_info(:start_subscriber, %{started: true} = state), do: {:noreply, state}

  def handle_info(:start_subscriber, state) do
    case :hecate_om.mesh_handles() do
      {:ok, pool, realm} ->
        start_subscriber(pool, realm)

        Logger.info(
          "[ShapeMeshSubscriberStarter] subscribed #{ProjectBoards.ShapeMeshSubscriber.topic()}"
        )

        {:noreply, %{state | started: true}}

      other ->
        Logger.warning("[ShapeMeshSubscriberStarter] mesh_handles: #{inspect(other)}, retrying")
        Process.send_after(self(), :start_subscriber, @retry_ms)
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp start_subscriber(pool, realm) do
    spec = %{
      id: ProjectBoards.ShapeMeshSubscriber,
      start:
        {:macula_subscriber, :start_link,
         [
           ProjectBoards.ShapeMeshSubscriber,
           pool,
           realm,
           ProjectBoards.ShapeMeshSubscriber.topic(),
           [],
           %{}
         ]},
      restart: :permanent
    }

    case DynamicSupervisor.start_child(ProjectBoards.MeshSubscriberSupervisor, spec) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning("[ShapeMeshSubscriberStarter] subscribe failed: #{inspect(reason)}")
        :ok
    end
  end
end
