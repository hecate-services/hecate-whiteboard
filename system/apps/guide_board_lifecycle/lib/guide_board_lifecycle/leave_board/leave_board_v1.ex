defmodule GuideBoardLifecycle.LeaveBoard.LeaveBoardV1 do
  # Command: leave_board_v1 -- a peer's graceful exit from a board's
  # presence session. The one presence fact worth an audit trail (see
  # plans/PLAN_HECATE_WHITEBOARD_ROOT.md's "Presence is not event-sourced"
  # decision) -- a silent disconnect is not one of these, it's aged out by
  # TrackPresence's own sweep instead.
  @behaviour :evoq_command

  defstruct [:board_id, :peer_id]

  @impl true
  def command_type, do: :leave_board

  @impl true
  def new(%{board_id: id, peer_id: peer_id})
      when is_binary(id) and id != "" and is_binary(peer_id) and peer_id != "" do
    {:ok, %__MODULE__{board_id: id, peer_id: peer_id}}
  end

  def new(%{board_id: id}) when is_binary(id) and id != "", do: {:error, :peer_id_required}
  def new(_), do: {:error, :board_id_required}

  @impl true
  def to_map(%__MODULE__{} = cmd),
    do: %{command_type: command_type(), board_id: cmd.board_id, peer_id: cmd.peer_id}

  @impl true
  def from_map(%{board_id: id, peer_id: peer_id}),
    do: {:ok, %__MODULE__{board_id: id, peer_id: peer_id}}

  def from_map(_), do: {:error, :missing_required_fields}

  def board_id(%__MODULE__{board_id: v}), do: v
  def peer_id(%__MODULE__{peer_id: v}), do: v
end
