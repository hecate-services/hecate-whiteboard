defmodule ProjectBoards.ShapeLifecycleMeshSubscriberStarter do
  # Starts three :macula_subscriber children (one per shape-lifecycle
  # topic) once the shared mesh pool is up, then stops retrying -- same
  # shape as BoardLifecycleMeshSubscriberStarter, just against
  # ShapeLifecycleMeshSubscriber's three topics. Replaces
  # BoardMeshSubscriberStarter and ShapeMeshSubscriberStarter.
  use GenServer
  require Logger

  @retry_ms 5_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    send(self(), :start_subscribers)
    {:ok, %{started: false}}
  end

  @impl true
  def handle_info(:start_subscribers, %{started: true} = state), do: {:noreply, state}

  def handle_info(:start_subscribers, state) do
    case :hecate_om.mesh_handles() do
      {:ok, pool, realm} ->
        Enum.each(
          ProjectBoards.ShapeLifecycleMeshSubscriber.topics(),
          &start_subscriber(pool, realm, &1)
        )

        Logger.info(
          "[ShapeLifecycleMeshSubscriberStarter] subscribed #{length(ProjectBoards.ShapeLifecycleMeshSubscriber.topics())} shape-lifecycle topics"
        )

        {:noreply, %{state | started: true}}

      other ->
        Logger.warning(
          "[ShapeLifecycleMeshSubscriberStarter] mesh_handles: #{inspect(other)}, retrying"
        )

        Process.send_after(self(), :start_subscribers, @retry_ms)
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp start_subscriber(pool, realm, topic) do
    spec = %{
      id: {ProjectBoards.ShapeLifecycleMeshSubscriber, topic},
      start:
        {:macula_subscriber, :start_link,
         [ProjectBoards.ShapeLifecycleMeshSubscriber, pool, realm, topic, [], %{}]},
      restart: :permanent
    }

    case DynamicSupervisor.start_child(ProjectBoards.MeshSubscriberSupervisor, spec) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[ShapeLifecycleMeshSubscriberStarter] subscribe(#{topic}) failed: #{inspect(reason)}"
        )

        :ok
    end
  end
end
