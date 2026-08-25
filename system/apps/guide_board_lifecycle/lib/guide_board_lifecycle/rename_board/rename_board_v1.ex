defmodule GuideBoardLifecycle.RenameBoard.RenameBoardV1 do
  # Command: rename_board_v1 -- changes an existing board's title. Title is
  # set once at initiate_board time with no way to change it after; this is
  # that missing desk.
  @behaviour :evoq_command

  defstruct [:board_id, :title]

  @impl true
  def command_type, do: :rename_board

  @impl true
  def new(%{board_id: id, title: title})
      when is_binary(id) and id != "" and is_binary(title) and title != "" do
    {:ok, %__MODULE__{board_id: id, title: title}}
  end

  def new(%{board_id: id}) when is_binary(id) and id != "", do: {:error, :title_required}
  def new(_), do: {:error, :board_id_required}

  @impl true
  def to_map(%__MODULE__{} = cmd),
    do: %{command_type: command_type(), board_id: cmd.board_id, title: cmd.title}

  @impl true
  def from_map(%{board_id: id, title: title}), do: {:ok, %__MODULE__{board_id: id, title: title}}
  def from_map(_), do: {:error, :missing_required_fields}

  def board_id(%__MODULE__{board_id: v}), do: v
  def title(%__MODULE__{title: v}), do: v
end
