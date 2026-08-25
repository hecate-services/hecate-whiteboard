defmodule GuideBoardLifecycle.PlaceSticky.PlaceStickyV1 do
  # Command: place_sticky_v1 -- drops one sticky note on a hosted board.
  # shape_id is a plain random id, not a reckon_gater stream id -- a
  # sticky isn't its own aggregate/stream, just a value inside the
  # board's, same reasoning as DrawStrokeV1's own stroke_id.
  @behaviour :evoq_command

  defstruct [:board_id, :shape_id, :x, :y, :color, :text]

  @impl true
  def command_type, do: :place_sticky

  @impl true
  def new(%{board_id: board_id, x: x, y: y} = params)
      when is_binary(board_id) and board_id != "" and is_number(x) and is_number(y) do
    {:ok,
     %__MODULE__{
       board_id: board_id,
       shape_id: random_id(),
       x: x,
       y: y,
       color: Map.get(params, :color, "#f2c94c"),
       text: Map.get(params, :text, "")
     }}
  end

  def new(_), do: {:error, :board_id_and_position_required}

  @impl true
  def to_map(%__MODULE__{} = cmd) do
    %{
      command_type: command_type(),
      board_id: cmd.board_id,
      shape_id: cmd.shape_id,
      x: cmd.x,
      y: cmd.y,
      color: cmd.color,
      text: cmd.text
    }
  end

  @impl true
  def from_map(%{board_id: id, shape_id: sid, x: x, y: y, color: color, text: text}) do
    {:ok, %__MODULE__{board_id: id, shape_id: sid, x: x, y: y, color: color, text: text}}
  end

  def from_map(_), do: {:error, :missing_required_fields}

  def board_id(%__MODULE__{board_id: v}), do: v
  def shape_id(%__MODULE__{shape_id: v}), do: v
  def x(%__MODULE__{x: v}), do: v
  def y(%__MODULE__{y: v}), do: v
  def color(%__MODULE__{color: v}), do: v
  def text(%__MODULE__{text: v}), do: v

  defp random_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
