defmodule GuideBoardLifecycle.LeaveBoard.PeerDepartedV1 do
  # Event: peer_departed_v1.
  @behaviour :evoq_event

  alias GuideBoardLifecycle.LeaveBoard.LeaveBoardV1

  defstruct [:board_id, :peer_id, :departed_at]

  @impl true
  def event_type, do: "peer_departed_v1"

  @impl true
  def new(%{board_id: id, peer_id: peer_id}) do
    %__MODULE__{board_id: id, peer_id: peer_id, departed_at: System.system_time(:millisecond)}
  end

  def from_command(%LeaveBoardV1{} = cmd) do
    new(%{board_id: LeaveBoardV1.board_id(cmd), peer_id: LeaveBoardV1.peer_id(cmd)})
  end

  @impl true
  def to_map(%__MODULE__{} = e) do
    %{
      event_type: event_type(),
      board_id: e.board_id,
      peer_id: e.peer_id,
      departed_at: e.departed_at
    }
  end

  def board_id(%__MODULE__{board_id: v}), do: v
  def peer_id(%__MODULE__{peer_id: v}), do: v
end
