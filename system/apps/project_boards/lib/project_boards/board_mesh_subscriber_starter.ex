defmodule ProjectBoards.BoardMeshSubscriberStarter do
  # Starts the BoardMeshSubscriber once the shared mesh pool is up, then
  # stops retrying -- :macula_subscriber.start_link/6 calls
  # macula:subscribe/5 synchronously inside its own init/1, so unlike a
  # bare macula:subscribe_callback/4 there is no built-in "retry until
  # the pool exists" behaviour to lean on. hecate_om:mesh_handles/0 can
  # return {:error, :mesh_unavailable} for a while after boot (the pool
  # connects asynchronously), so this mirrors macula-realm's own
  # Tube.SubscriberStarter, just for one topic instead of four.
  #
  # Known, accepted gap shared with every subscriber built this way: it
  # does not re-subscribe if the pool reconnects under a new link after
  # the initial subscribe succeeds (the SDK's own documented caveat) --
  # not solved here, matches Tube.SubscriberStarter's own stated scope.
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
          "[BoardMeshSubscriberStarter] subscribed #{ProjectBoards.BoardMeshSubscriber.topic()}"
        )

        {:noreply, %{state | started: true}}

      other ->
        Logger.warning("[BoardMeshSubscriberStarter] mesh_handles: #{inspect(other)}, retrying")
        Process.send_after(self(), :start_subscriber, @retry_ms)
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp start_subscriber(pool, realm) do
    spec = %{
      id: ProjectBoards.BoardMeshSubscriber,
      start:
        {:macula_subscriber, :start_link,
         [
           ProjectBoards.BoardMeshSubscriber,
           pool,
           realm,
           ProjectBoards.BoardMeshSubscriber.topic(),
           [],
           %{}
         ]},
      restart: :permanent
    }

    case DynamicSupervisor.start_child(ProjectBoards.MeshSubscriberSupervisor, spec) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning("[BoardMeshSubscriberStarter] subscribe failed: #{inspect(reason)}")
        :ok
    end
  end
end
