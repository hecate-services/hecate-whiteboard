defmodule GuideBoardLifecycle.ShapeMutation.AnswerShapeMutationRequestsStarter do
  # Starts AnswerShapeMutationRequests once the shared mesh pool is up,
  # then stops retrying -- mirrors AnswerDrawStrokeRequestsStarter
  # exactly, sharing the same GuideBoardLifecycle.MeshSubscriberSupervisor.
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
          "[AnswerShapeMutationRequestsStarter] subscribed #{GuideBoardLifecycle.ShapeMutation.AnswerShapeMutationRequests.topic()}"
        )

        {:noreply, %{state | started: true}}

      other ->
        Logger.warning(
          "[AnswerShapeMutationRequestsStarter] mesh_handles: #{inspect(other)}, retrying"
        )

        Process.send_after(self(), :start_subscriber, @retry_ms)
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp start_subscriber(pool, realm) do
    spec = %{
      id: GuideBoardLifecycle.ShapeMutation.AnswerShapeMutationRequests,
      start:
        {:macula_subscriber, :start_link,
         [
           GuideBoardLifecycle.ShapeMutation.AnswerShapeMutationRequests,
           pool,
           realm,
           GuideBoardLifecycle.ShapeMutation.AnswerShapeMutationRequests.topic(),
           [],
           %{}
         ]},
      restart: :permanent
    }

    case DynamicSupervisor.start_child(GuideBoardLifecycle.MeshSubscriberSupervisor, spec) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[AnswerShapeMutationRequestsStarter] subscribe failed: #{inspect(reason)}"
        )

        :ok
    end
  end
end
