defmodule GuideBoardLifecycle.InitiateBoard.InitiateBoardV1 do
  # Command: initiate_board_v1 -- opens a board's dossier. Mints the board's
  # id here (via reckon_gater_stream_id, not supplied by the caller) so it
  # is both a valid entity id and a valid stream id from the moment it
  # exists. `title` defaults to empty so a host can open a board with just
  # an owner and set the title later.
  @behaviour :evoq_command

  defstruct [:board_id, :owner, :title]

  @impl true
  def command_type, do: :initiate_board

  @impl true
  def new(%{owner: owner} = params) when is_binary(owner) and owner != "" do
    {:ok,
     %__MODULE__{
       board_id: :reckon_gater_stream_id.new("board"),
       owner: owner,
       title: Map.get(params, :title, "")
     }}
  end

  def new(_), do: {:error, :owner_required}

  @impl true
  def to_map(%__MODULE__{} = cmd) do
    %{
      command_type: command_type(),
      board_id: cmd.board_id,
      owner: cmd.owner,
      title: cmd.title
    }
  end

  # Reconstructs a typed command from the plain map the aggregate receives
  # as its command payload (built via to_map/1 by MaybeInitiateBoard).
  @impl true
  def from_map(%{board_id: id, owner: owner, title: title}) do
    {:ok, %__MODULE__{board_id: id, owner: owner, title: title}}
  end

  def from_map(_), do: {:error, :missing_required_fields}

  def board_id(%__MODULE__{board_id: v}), do: v
  def owner(%__MODULE__{owner: v}), do: v
  def title(%__MODULE__{title: v}), do: v
end
