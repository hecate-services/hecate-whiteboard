defmodule GuideBoardLifecycle.HostBoard.BoardHostedV1 do
  # Event: board_hosted_v1.
  @behaviour :evoq_event

  alias GuideBoardLifecycle.HostBoard.HostBoardV1

  defstruct [:board_id, :hosted_at]

  @impl true
  def event_type, do: "board_hosted_v1"

  @impl true
  def new(%{board_id: id}),
    do: %__MODULE__{board_id: id, hosted_at: System.system_time(:millisecond)}

  def from_command(%HostBoardV1{} = cmd), do: new(%{board_id: HostBoardV1.board_id(cmd)})

  @impl true
  def to_map(%__MODULE__{} = e) do
    %{event_type: event_type(), board_id: e.board_id, hosted_at: e.hosted_at}
  end

  def board_id(%__MODULE__{board_id: v}), do: v
end
