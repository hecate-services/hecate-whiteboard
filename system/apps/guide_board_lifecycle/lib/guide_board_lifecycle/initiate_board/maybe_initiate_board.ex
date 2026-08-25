defmodule GuideBoardLifecycle.InitiateBoard.MaybeInitiateBoard do
  # Handler for initiate_board_v1: builds the resulting event (called from
  # BoardAggregate.execute/2) and dispatches the command (called from
  # outside, e.g. host_board later, or a smoke test).
  alias GuideBoardLifecycle.BoardAggregate
  alias GuideBoardLifecycle.InitiateBoard.BoardInitiatedV1
  alias GuideBoardLifecycle.InitiateBoard.InitiateBoardV1

  def handle_from_map(payload) do
    case InitiateBoardV1.from_map(payload) do
      {:ok, cmd} -> handle(cmd)
      {:error, _} = error -> error
    end
  end

  def handle(%InitiateBoardV1{} = cmd) do
    event = BoardInitiatedV1.from_command(cmd)
    {:ok, [BoardInitiatedV1.to_map(event)]}
  end

  # Mint + dispatch: builds the command (minting the board id), wraps it as
  # an evoq command, and routes it to the aggregate. Returns the minted
  # board_id alongside the usual dispatch result so the caller can look the
  # new board up immediately.
  def dispatch(params) do
    case InitiateBoardV1.new(params) do
      {:ok, cmd} ->
        board_id = InitiateBoardV1.board_id(cmd)

        evoq_cmd =
          :evoq_command.new(
            :initiate_board,
            BoardAggregate,
            BoardAggregate.stream_id(board_id),
            InitiateBoardV1.to_map(cmd)
          )

        case :evoq_router.dispatch(evoq_cmd) do
          {:ok, version, events} -> {:ok, board_id, version, events}
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end
end
