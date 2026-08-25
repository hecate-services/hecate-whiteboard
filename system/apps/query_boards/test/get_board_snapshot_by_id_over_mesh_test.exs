defmodule QueryBoards.GetBoardSnapshotByIdOverMeshTest do
  # The actual mesh round trip (query publish -> AnswerBoardSnapshotQueries
  # reply -> materialize) can only be exercised against a live pool -- this
  # dev/test sandbox genuinely cannot reach the mesh (same limitation noted
  # for BoardMeshSubscriber's own live verification). What's testable here
  # without one: the short-circuit when hecate_om has no pool yet.
  use ExUnit.Case, async: false

  alias QueryBoards.GetBoardSnapshotByIdOverMesh.GetBoardSnapshotByIdOverMesh

  test "returns an error immediately when the mesh pool isn't up, no timeout wait" do
    assert {:error, {:mesh_unavailable, _}} =
             GetBoardSnapshotByIdOverMesh.call("board-nonexistent", 50)
  end
end
