defmodule GuideBoardLifecycle.InitiateBoard.BoardInitiatedV1 do
  # Event: board_initiated_v1.
  @behaviour :evoq_event

  alias GuideBoardLifecycle.InitiateBoard.InitiateBoardV1

  defstruct [:board_id, :owner, :title, :initiated_at]

  # The spec technically wants an atom here, but evoq's own runtime
  # tolerates either and this workspace's real, deployed code (hecate-tube)
  # uses a binary -- followed that convention. See
  # plans/PLAN_HECATE_WHITEBOARD_ROOT.md's hard-won-facts section.
  @impl true
  def event_type, do: "board_initiated_v1"

  @impl true
  def new(%{board_id: id, owner: owner, title: title}) do
    %__MODULE__{
      board_id: id,
      owner: owner,
      title: title,
      initiated_at: System.system_time(:millisecond)
    }
  end

  def from_command(%InitiateBoardV1{} = cmd) do
    new(%{
      board_id: InitiateBoardV1.board_id(cmd),
      owner: InitiateBoardV1.owner(cmd),
      title: InitiateBoardV1.title(cmd)
    })
  end

  @impl true
  def to_map(%__MODULE__{} = e) do
    %{
      event_type: event_type(),
      board_id: e.board_id,
      owner: e.owner,
      title: e.title,
      initiated_at: e.initiated_at
    }
  end

  def board_id(%__MODULE__{board_id: v}), do: v
end
