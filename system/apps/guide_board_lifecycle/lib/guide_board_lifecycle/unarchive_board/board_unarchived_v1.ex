defmodule GuideBoardLifecycle.UnarchiveBoard.BoardUnarchivedV1 do
  # Event: board_unarchived_v1.
  @behaviour :evoq_event

  alias GuideBoardLifecycle.UnarchiveBoard.UnarchiveBoardV1

  defstruct [:board_id, :unarchived_at]

  @impl true
  def event_type, do: "board_unarchived_v1"

  @impl true
  def new(%{board_id: id}) do
    %__MODULE__{board_id: id, unarchived_at: System.system_time(:millisecond)}
  end

  def from_command(%UnarchiveBoardV1{} = cmd),
    do: new(%{board_id: UnarchiveBoardV1.board_id(cmd)})

  @impl true
  def to_map(%__MODULE__{} = e) do
    %{event_type: event_type(), board_id: e.board_id, unarchived_at: e.unarchived_at}
  end

  def board_id(%__MODULE__{board_id: v}), do: v
end
