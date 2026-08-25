defmodule GuideBoardLifecycle.DrawStroke.AnswerDrawStrokeRequestsStarter do
  # Starts AnswerDrawStrokeRequests once the shared mesh pool is up, then
  # stops retrying -- mirrors ProjectBoards.ShapeLifecycleMeshSubscriberStarter/
  # QueryBoards.AnswerBoardSnapshotQueriesStarter exactly. First INBOUND
  # mesh subscriber in this app -- ShapeLifecycleV1ToMesh only ever
  # publishes outbound, so this needs its own DynamicSupervisor rather
  # than reaching into another app's.
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
          "[AnswerDrawStrokeRequestsStarter] subscribed #{GuideBoardLifecycle.DrawStroke.AnswerDrawStrokeRequests.topic()}"
        )

        {:noreply, %{state | started: true}}

      other ->
        Logger.warning(
          "[AnswerDrawStrokeRequestsStarter] mesh_handles: #{inspect(other)}, retrying"
        )

        Process.send_after(self(), :start_subscriber, @retry_ms)
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp start_subscriber(pool, realm) do
    spec = %{
      id: GuideBoardLifecycle.DrawStroke.AnswerDrawStrokeRequests,
      start:
        {:macula_subscriber, :start_link,
         [
           GuideBoardLifecycle.DrawStroke.AnswerDrawStrokeRequests,
           pool,
           realm,
           GuideBoardLifecycle.DrawStroke.AnswerDrawStrokeRequests.topic(),
           [],
           %{}
         ]},
      restart: :permanent
    }

    case DynamicSupervisor.start_child(GuideBoardLifecycle.MeshSubscriberSupervisor, spec) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning("[AnswerDrawStrokeRequestsStarter] subscribe failed: #{inspect(reason)}")
        :ok
    end
  end
end
