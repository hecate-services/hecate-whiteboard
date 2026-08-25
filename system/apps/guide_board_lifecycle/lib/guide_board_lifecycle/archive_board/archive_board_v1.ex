defmodule GuideBoardLifecycle.ArchiveBoard.ArchiveBoardV1 do
  # Command: archive_board_v1 -- retires an existing board's dossier. The
  # death end of the walking skeleton, paired with initiate_board's birth.
  @behaviour :evoq_command

  defstruct [:board_id]

  @impl true
  def command_type, do: :archive_board

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
