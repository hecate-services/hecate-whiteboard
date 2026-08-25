defmodule GuideBoardLifecycle.RemoveShape.RemoveShapeV1 do
  # Command: remove_shape_v1 -- deletes an existing shape (stroke, sticky,
  # or text label) from a hosted board. Works identically across shape
  # kinds -- see MoveShapeV1's own header for why board_shapes rows carry
  # a uniform shape_id regardless of origin.
  @behaviour :evoq_command

  defstruct [:board_id, :shape_id]

  @impl true
  def command_type, do: :remove_shape

  @impl true
  def new(%{board_id: board_id, shape_id: shape_id})
      when is_binary(board_id) and board_id != "" and is_binary(shape_id) and shape_id != "" do
    {:ok, %__MODULE__{board_id: board_id, shape_id: shape_id}}
  end

  def new(_), do: {:error, :board_id_and_shape_id_required}

  @impl true
  def to_map(%__MODULE__{} = cmd),
    do: %{command_type: command_type(), board_id: cmd.board_id, shape_id: cmd.shape_id}

  @impl true
  def from_map(%{board_id: id, shape_id: sid}),
    do: {:ok, %__MODULE__{board_id: id, shape_id: sid}}

  def from_map(_), do: {:error, :missing_required_fields}

  def board_id(%__MODULE__{board_id: v}), do: v
  def shape_id(%__MODULE__{shape_id: v}), do: v
end
