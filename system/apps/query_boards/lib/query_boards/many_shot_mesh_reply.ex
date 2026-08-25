defmodule QueryBoards.ManyShotMeshReply do
  # :macula_subscriber callback for collecting a REPLY FROM EVERY RESPONDER
  # on an ephemeral topic, not just the first (contrast
  # QueryBoards.OneShotMeshReply, used by join_board where exactly one
  # authoritative host answers). Forwards every event to the owner pid and
  # keeps running -- the owner is responsible for stopping this subscriber
  # once its collection window closes (see ListBoardsOverMesh). Used by
  # board-list discovery, where every host on the mesh may legitimately
  # answer the same query.
  @behaviour :macula_subscriber

  @impl true
  def init(owner_pid), do: {:ok, owner_pid}

  @impl true
  def handle_event(_topic, payload, _meta, owner) do
    send(owner, {:mesh_reply, payload})
    {:noreply, owner}
  end
end
