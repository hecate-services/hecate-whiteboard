defmodule GuideBoardLifecycle.ArchiveBoard.BoardArchivedV1 do
  # Event: board_archived_v1.
  @behaviour :evoq_event

  alias GuideBoardLifecycle.ArchiveBoard.ArchiveBoardV1

  defstruct [:board_id, :archived_at]

  @impl true
  def event_type, do: "board_archived_v1"

  @impl true
  def new(%{board_id: id}) do
    %__MODULE__{board_id: id, archived_at: System.system_time(:millisecond)}
  end

  def from_command(%ArchiveBoardV1{} = cmd), do: new(%{board_id: ArchiveBoardV1.board_id(cmd)})

  @impl true
  def to_map(%__MODULE__{} = e) do
    %{event_type: event_type(), board_id: e.board_id, archived_at: e.archived_at}
  end

  def board_id(%__MODULE__{board_id: v}), do: v
end
