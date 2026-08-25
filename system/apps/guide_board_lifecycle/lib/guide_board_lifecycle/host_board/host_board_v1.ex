defmodule GuideBoardLifecycle.HostBoard.HostBoardV1 do
  # Command: host_board_v1 -- opens an already-initiated board for live
  # mesh connections. Separate from initiate_board on purpose: creation
  # and activation are different events even when they happen back to
  # back (see plans/PLAN_HECATE_WHITEBOARD_ROOT.md).
  @behaviour :evoq_command

  defstruct [:board_id]

  @impl true
  def command_type, do: :host_board

  @impl true
  def new(%{board_id: id}) when is_binary(id) and id != "", do: {:ok, %__MODULE__{board_id: id}}
  def new(_), do: {:error, :board_id_required}

  @impl true
  def to_map(%__MODULE__{} = cmd), do: %{command_type: command_type(), board_id: cmd.board_id}

  @impl true
  def from_map(%{board_id: id}), do: {:ok, %__MODULE__{board_id: id}}
  def from_map(_), do: {:error, :missing_required_fields}

  def board_id(%__MODULE__{board_id: v}), do: v
end
