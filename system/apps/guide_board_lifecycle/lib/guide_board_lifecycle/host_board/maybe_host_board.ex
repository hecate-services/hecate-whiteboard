defmodule GuideBoardLifecycle.HostBoard.MaybeHostBoard do
  # Handler for host_board_v1 -- mirrors MaybeInitiateBoard's shape.
  alias GuideBoardLifecycle.BoardAggregate
  alias GuideBoardLifecycle.HostBoard.BoardHostedV1
  alias GuideBoardLifecycle.HostBoard.HostBoardV1

  def handle_from_map(payload) do
    case HostBoardV1.from_map(payload) do
      {:ok, cmd} -> handle(cmd)
      {:error, _} = error -> error
    end
  end

  def handle(%HostBoardV1{} = cmd) do
    event = BoardHostedV1.from_command(cmd)
    {:ok, [BoardHostedV1.to_map(event)]}
  end

  def dispatch(%{board_id: board_id} = params) do
    case HostBoardV1.new(params) do
      {:ok, cmd} ->
        evoq_cmd =
          :evoq_command.new(
            :host_board,
            BoardAggregate,
            BoardAggregate.stream_id(board_id),
            HostBoardV1.to_map(cmd)
          )

        :evoq_router.dispatch(evoq_cmd)

      {:error, _} = error ->
        error
    end
  end
end
