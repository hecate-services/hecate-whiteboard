defmodule GuideBoardLifecycle.BoardAggregate do
  # The `board` aggregate: routes commands to a desk handler after checking
  # the business rule for that command against current status. Mirrors
  # hecate-tube's channel_aggregate.
  @behaviour :evoq_aggregate

  alias GuideBoardLifecycle.ArchiveBoard.MaybeArchiveBoard
  alias GuideBoardLifecycle.BoardState
  alias GuideBoardLifecycle.BoardStatus
  alias GuideBoardLifecycle.DrawStroke.MaybeDrawStroke
  alias GuideBoardLifecycle.HostBoard.MaybeHostBoard
  alias GuideBoardLifecycle.InitiateBoard.MaybeInitiateBoard

  @impl true
  def state_module, do: BoardState

  @impl true
  def init(board_id), do: {:ok, BoardState.new(board_id)}

  @impl true
  def apply(state, event), do: BoardState.apply_event(state, event)

  @impl true
  def execute(state, %{command_type: command_type} = payload) do
    do_execute(command_type, BoardState.status(state), payload)
  end

  defp do_execute(:initiate_board, status, payload) do
    if :evoq_bit_flags.has_not(status, BoardStatus.initiated()) do
      MaybeInitiateBoard.handle_from_map(payload)
    else
      {:error, :already_initiated}
    end
  end

  defp do_execute(:archive_board, status, payload) do
    cond do
      :evoq_bit_flags.has_not(status, BoardStatus.initiated()) -> {:error, :not_initiated}
      :evoq_bit_flags.has(status, BoardStatus.archived()) -> {:error, :already_archived}
      true -> MaybeArchiveBoard.handle_from_map(payload)
    end
  end

  defp do_execute(:host_board, status, payload) do
    cond do
      :evoq_bit_flags.has_not(status, BoardStatus.initiated()) -> {:error, :not_initiated}
      :evoq_bit_flags.has(status, BoardStatus.archived()) -> {:error, :archived}
      true -> MaybeHostBoard.handle_from_map(payload)
    end
  end

  defp do_execute(:draw_stroke, status, payload) do
    cond do
      :evoq_bit_flags.has_not(status, BoardStatus.hosted()) -> {:error, :not_hosted}
      :evoq_bit_flags.has(status, BoardStatus.archived()) -> {:error, :archived}
      true -> MaybeDrawStroke.handle_from_map(payload)
    end
  end

  defp do_execute(_other, _status, _payload), do: {:error, :unknown_command}

  # A board's id is minted (via reckon_gater_stream_id, in
  # InitiateBoardV1.new/1) at the same moment it becomes a stream id -- no
  # separate derivation needed.
  def stream_id(board_id), do: board_id
end
