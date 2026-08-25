defmodule QueryBoards.OneShotMeshReply do
  # :macula_subscriber callback for a single expected reply on an
  # ephemeral, per-request topic -- forwards the first event to the owner
  # pid that started it and stops itself. Used by
  # GetBoardSnapshotByIdOverMesh to wait on its own reply_to topic without
  # touching macula:subscribe/5 directly (see macula_subscriber's own doc:
  # this is the supervised primitive, not a hand-rolled raw subscribe).
  #
  # The gen_server this wraps stays linked to whichever process called
  # :macula_subscriber.start_link/6 (a plain gen_server:start_link/3
  # underneath) -- a normal {:stop, :normal, _} exit here does not
  # propagate to that linked caller, so the caller is free to `receive`
  # for the forwarded message and, on timeout, explicitly stop this pid
  # itself to avoid leaking a dangling subscription.
  @behaviour :macula_subscriber

  @impl true
  def init(owner_pid), do: {:ok, owner_pid}

  @impl true
  def handle_event(_topic, payload, _meta, owner) do
    send(owner, {:one_shot_mesh_reply, payload})
    {:stop, :normal, owner}
  end
end
