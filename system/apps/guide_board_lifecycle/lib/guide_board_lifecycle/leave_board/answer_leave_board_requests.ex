defmodule GuideBoardLifecycle.LeaveBoard.AnswerLeaveBoardRequests do
  # Write-relay receiving side for leave_board -- mirrors
  # AnswerDrawStrokeRequests exactly. Every node subscribes; dispatching
  # against a board this node doesn't host returns {:error, :not_hosted}
  # and is silently dropped, same authority-check-for-free trick.
  @behaviour :macula_subscriber

  alias GuideBoardLifecycle.LeaveBoard.MaybeLeaveBoard

  require Logger

  @topic "io.macula/whiteboard-commons/whiteboard/leave_board_request_v1"

  def topic, do: @topic

  @impl true
  def init(_args), do: {:ok, nil}

  @impl true
  def handle_event(@topic, payload, _meta, state) do
    fact = normalize(payload)

    case MaybeLeaveBoard.dispatch(%{
           board_id: field(:board_id, fact),
           peer_id: field(:peer_id, fact)
         }) do
      {:ok, _version, _events} ->
        Logger.info("[AnswerLeaveBoardRequests] handled relay for #{field(:board_id, fact)}")

      {:error, :not_hosted} ->
        :ok

      {:error, reason} ->
        Logger.warning("[AnswerLeaveBoardRequests] relay dispatch failed: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def handle_event(_topic, _payload, _meta, state), do: {:noreply, state}

  defp field(key, map) when is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp normalize({:text, b}) when is_binary(b), do: b
  defp normalize(:undefined), do: nil
  defp normalize(m) when is_map(m), do: Map.new(m, fn {k, v} -> {normalize(k), normalize(v)} end)
  defp normalize(l) when is_list(l), do: Enum.map(l, &normalize/1)
  defp normalize(v), do: v
end
