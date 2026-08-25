defmodule GuideBoardLifecycle.RenameBoard.BoardRenamedV1 do
  # Event: board_renamed_v1.
  @behaviour :evoq_event

  alias GuideBoardLifecycle.RenameBoard.RenameBoardV1

  defstruct [:board_id, :title, :renamed_at]

  @impl true
  def event_type, do: "board_renamed_v1"

  @impl true
  def new(%{board_id: id, title: title}) do
    %__MODULE__{board_id: id, title: title, renamed_at: System.system_time(:millisecond)}
  end

  def from_command(%RenameBoardV1{} = cmd) do
    new(%{board_id: RenameBoardV1.board_id(cmd), title: RenameBoardV1.title(cmd)})
  end

  @impl true
  def to_map(%__MODULE__{} = e) do
    %{event_type: event_type(), board_id: e.board_id, title: e.title, renamed_at: e.renamed_at}
  end

  def board_id(%__MODULE__{board_id: v}), do: v
end
