defmodule GuideBoardLifecycle.ShapeMutation.AnswerShapeMutationRequests do
  # Write-relay for a joining (non-hosting) peer's shape mutations --
  # place_sticky, place_text, move_shape, remove_shape. One shared topic
  # for all four (mirrors AnswerDrawStrokeRequests' per-topic design, but
  # consolidated: these four are siblings of one "shape mutation" concern,
  # not separate features like draw_stroke vs rename_board, so sharing
  # the relay plumbing avoids four near-identical subscriber/starter
  # pairs). Every node subscribes; the embedded command_type field picks
  # which desk's dispatch/1 handles it, and that desk's own BoardAggregate
  # guard (:not_hosted) makes every node except the real host a safe
  # no-op -- exactly the authority-check-for-free trick draw_stroke's
  # write-relay already uses.
  @behaviour :macula_subscriber

  alias GuideBoardLifecycle.MoveShape.MaybeMoveShape
  alias GuideBoardLifecycle.PlaceSticky.MaybePlaceSticky
  alias GuideBoardLifecycle.PlaceText.MaybePlaceText
  alias GuideBoardLifecycle.RemoveShape.MaybeRemoveShape

  require Logger

  @topic "io.macula/whiteboard-commons/whiteboard/shape_mutation_request_v1"

  def topic, do: @topic

  @impl true
  def init(_args), do: {:ok, nil}

  @impl true
  def handle_event(@topic, payload, _meta, state) do
    fact = normalize(payload)
    command_type = field(:command_type, fact)
    board_id = field(:board_id, fact)

    result =
      case command_type do
        "place_sticky" ->
          MaybePlaceSticky.dispatch(%{
            board_id: board_id,
            x: field(:x, fact),
            y: field(:y, fact),
            color: field(:color, fact),
            text: field(:text, fact)
          })

        "place_text" ->
          MaybePlaceText.dispatch(%{
            board_id: board_id,
            x: field(:x, fact),
            y: field(:y, fact),
            color: field(:color, fact),
            text: field(:text, fact)
          })

        "move_shape" ->
          MaybeMoveShape.dispatch(%{
            board_id: board_id,
            shape_id: field(:shape_id, fact),
            points: field(:points, fact)
          })

        "remove_shape" ->
          MaybeRemoveShape.dispatch(%{board_id: board_id, shape_id: field(:shape_id, fact)})

        other ->
          {:error, {:unknown_command_type, other}}
      end

    case result do
      {:ok, _version, _events} ->
        Logger.info("[AnswerShapeMutationRequests] handled #{command_type} for #{board_id}")

      {:error, :not_hosted} ->
        :ok

      {:error, reason} ->
        Logger.warning("[AnswerShapeMutationRequests] dispatch failed: #{inspect(reason)}")
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
