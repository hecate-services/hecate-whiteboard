defmodule GuideBoardLifecycle.LeaveBoard.MaybeLeaveBoard do
  # Handler for leave_board_v1 -- mirrors MaybeDrawStroke's shape,
  # including the same write-relay split (dispatch locally if this node
  # hosts the board, relay over mesh to the real host otherwise). See
  # AnswerLeaveBoardRequests for the receiving half.
  alias GuideBoardLifecycle.BoardAggregate
  alias GuideBoardLifecycle.LeaveBoard.AnswerLeaveBoardRequests
  alias GuideBoardLifecycle.LeaveBoard.LeaveBoardV1
  alias GuideBoardLifecycle.LeaveBoard.PeerDepartedV1

  require Logger

  def handle_from_map(payload) do
    case LeaveBoardV1.from_map(payload) do
      {:ok, cmd} -> handle(cmd)
      {:error, _} = error -> error
    end
  end

  def handle(%LeaveBoardV1{} = cmd) do
    event = PeerDepartedV1.from_command(cmd)
    {:ok, [PeerDepartedV1.to_map(event)]}
  end

  def dispatch(%{board_id: board_id} = params) do
    case LeaveBoardV1.new(params) do
      {:ok, cmd} ->
        evoq_cmd =
          :evoq_command.new(
            :leave_board,
            BoardAggregate,
            BoardAggregate.stream_id(board_id),
            LeaveBoardV1.to_map(cmd)
          )

        :evoq_router.dispatch(evoq_cmd)

      {:error, _} = error ->
        error
    end
  end

  def relay(%{board_id: board_id} = params) do
    case :hecate_om.mesh_handles() do
      {:ok, pool, realm} ->
        result =
          :macula_publisher.start_link(
            GuideBoardLifecycle.MeshPublisher,
            pool,
            realm,
            AnswerLeaveBoardRequests.topic(),
            params,
            []
          )

        Logger.info("[MaybeLeaveBoard] relay #{board_id}: #{inspect(result)}")
        :ok

      other ->
        Logger.warning("[MaybeLeaveBoard] mesh_handles: #{inspect(other)}, dropping relay")
        {:error, :mesh_unavailable}
    end
  end
end
