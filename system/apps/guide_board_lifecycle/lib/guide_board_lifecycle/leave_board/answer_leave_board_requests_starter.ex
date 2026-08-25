defmodule GuideBoardLifecycle.LeaveBoard.AnswerLeaveBoardRequestsStarter do
  # Starts AnswerLeaveBoardRequests once the shared mesh pool is up, then
  # stops retrying -- mirrors AnswerDrawStrokeRequestsStarter exactly,
  # sharing the same GuideBoardLifecycle.MeshSubscriberSupervisor.
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
          "[AnswerLeaveBoardRequestsStarter] subscribed #{GuideBoardLifecycle.LeaveBoard.AnswerLeaveBoardRequests.topic()}"
        )

        {:noreply, %{state | started: true}}

      other ->
        Logger.warning(
          "[AnswerLeaveBoardRequestsStarter] mesh_handles: #{inspect(other)}, retrying"
        )

        Process.send_after(self(), :start_subscriber, @retry_ms)
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp start_subscriber(pool, realm) do
    spec = %{
      id: GuideBoardLifecycle.LeaveBoard.AnswerLeaveBoardRequests,
      start:
        {:macula_subscriber, :start_link,
         [
           GuideBoardLifecycle.LeaveBoard.AnswerLeaveBoardRequests,
           pool,
           realm,
           GuideBoardLifecycle.LeaveBoard.AnswerLeaveBoardRequests.topic(),
           [],
           %{}
         ]},
      restart: :permanent
    }

    case DynamicSupervisor.start_child(GuideBoardLifecycle.MeshSubscriberSupervisor, spec) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning("[AnswerLeaveBoardRequestsStarter] subscribe failed: #{inspect(reason)}")
        :ok
    end
  end
end
