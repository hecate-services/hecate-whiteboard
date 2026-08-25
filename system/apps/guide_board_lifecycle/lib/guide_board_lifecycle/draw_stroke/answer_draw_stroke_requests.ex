defmodule GuideBoardLifecycle.DrawStroke.AnswerDrawStrokeRequests do
  # Write-relay for a joining (non-hosting) peer. Permanently subscribed
  # to a fixed topic on every node; a relayed stroke is just dispatched
  # through MaybeDrawStroke.dispatch/1 -- the SAME function a local draw
  # already uses -- and lets BoardAggregate's own business rule do the
  # authority check for free: on every node except the real host,
  # dispatching against a board this node never hosted returns
  # {:error, :not_hosted} (or the board doesn't exist locally at all,
  # same result), and the request is silently dropped. On the real host
  # it succeeds exactly like a local draw would, and the normal
  # shape_initiated_v1 -> ShapeLifecycleV1ToMesh -> ShapeLifecycleMeshSubscriber
  # path carries it back out to every peer, including whoever relayed it --
  # no reply needed here at all, the confirmation IS the replicated
  # stroke arriving through the path a joining peer already watches to
  # view the board in the first place.
  @behaviour :macula_subscriber

  alias GuideBoardLifecycle.DrawStroke.MaybeDrawStroke

  require Logger

  @topic "io.macula/whiteboard-commons/whiteboard/draw_stroke_request_v1"

  def topic, do: @topic

  @impl true
  def init(_args), do: {:ok, nil}

  @impl true
  def handle_event(@topic, payload, _meta, state) do
    fact = normalize(payload)

    case MaybeDrawStroke.dispatch(%{
           board_id: field(:board_id, fact),
           points: field(:points, fact),
           color: field(:color, fact),
           width: field(:width, fact)
         }) do
      {:ok, _version, _events} ->
        Logger.info("[AnswerDrawStrokeRequests] handled relay for #{field(:board_id, fact)}")

      # Every node except the real host gets this -- expected, frequent,
      # not worth logging (would fire on every stroke, on every peer,
      # forever).
      {:error, :not_hosted} ->
        :ok

      {:error, reason} ->
        Logger.warning("[AnswerDrawStrokeRequests] relay dispatch failed: #{inspect(reason)}")
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
