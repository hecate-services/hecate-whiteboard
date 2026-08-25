defmodule GuideBoardLifecycle.BoardState do
  # The `board` aggregate's state: identity, metadata, and status. Owns the
  # data shape; BoardAggregate owns command validation and business rules.
  @behaviour :evoq_state

  alias GuideBoardLifecycle.BoardStatus

  defstruct board_id: nil, owner: nil, title: nil, status: 0

  @impl true
  def new(board_id), do: %__MODULE__{board_id: board_id, status: 0}

  @impl true
  def apply_event(state, event), do: do_apply(field(:event_type, event), state, event)

  defp do_apply("board_initiated_v1", state, event) do
    %__MODULE__{
      state
      | owner: field(:owner, event),
        title: field(:title, event),
        status: Bitwise.bor(state.status, BoardStatus.initiated())
    }
  end

  defp do_apply("board_archived_v1", state, _event) do
    %__MODULE__{state | status: Bitwise.bor(state.status, BoardStatus.archived())}
  end

  defp do_apply(_other, state, _event), do: state

  @impl true
  def to_map(%__MODULE__{} = s) do
    %{board_id: s.board_id, owner: s.owner, title: s.title, status: s.status}
  end

  def status(%__MODULE__{status: v}), do: v

  # Tolerates atom or binary keys -- events replayed from storage arrive
  # with whatever key shape the adapter round-tripped them as. See
  # plans/PLAN_HECATE_WHITEBOARD_ROOT.md's "event shape on the wire" note.
  defp field(key, map) when is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end
end
