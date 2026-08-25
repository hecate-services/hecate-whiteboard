defmodule QueryBoards.ListBoardsOverMeshTest do
  # merge/1 is the one piece of real logic here that's pure -- the actual
  # mesh round trip (publish query -> AnswerBoardListQueries replies ->
  # collect over a window) needs a live pool, same limitation as
  # GetBoardSnapshotByIdOverMeshTest.
  use ExUnit.Case, async: true

  alias QueryBoards.ListBoardsOverMesh.ListBoardsOverMesh

  test "flattens boards from multiple host replies, tagging each with its host" do
    replies = [
      %{
        host: "beam01.lab",
        boards: [%{board_id: "board-a", title: "A", owner: "raf", stroke_count: 2}]
      },
      %{
        host: "beam02.lab",
        boards: [%{board_id: "board-b", title: "B", owner: "raf", stroke_count: 0}]
      }
    ]

    merged = ListBoardsOverMesh.merge(replies)

    assert [
             %{board_id: "board-a", host: "beam01.lab"},
             %{board_id: "board-b", host: "beam02.lab"}
           ] =
             Enum.map(merged, &Map.take(&1, [:board_id, :host]))
  end

  test "the same board_id from two hosts (symmetric-gossip default board) dedups, first reply wins" do
    replies = [
      %{
        host: "beam01.lab",
        boards: [%{board_id: "board-x", title: "X", owner: "a", stroke_count: 5}]
      },
      %{
        host: "beam02.lab",
        boards: [%{board_id: "board-x", title: "X", owner: "a", stroke_count: 3}]
      }
    ]

    assert [%{board_id: "board-x", host: "beam01.lab", stroke_count: 5}] =
             ListBoardsOverMesh.merge(replies)
  end

  test "sorts the merged result by title" do
    replies = [
      %{
        host: "beam01.lab",
        boards: [%{board_id: "board-z", title: "Zebra", owner: "a", stroke_count: 0}]
      },
      %{
        host: "beam02.lab",
        boards: [%{board_id: "board-a", title: "Apple", owner: "a", stroke_count: 0}]
      }
    ]

    assert [%{title: "Apple"}, %{title: "Zebra"}] = ListBoardsOverMesh.merge(replies)
  end

  test "no replies merges to an empty list" do
    assert ListBoardsOverMesh.merge([]) == []
  end

  # The atom/{text,_} key-shape tolerance is real (same as every other
  # mesh-facing module here) but lives in normalize/1, applied upstream in
  # collect/2 BEFORE merge/1 ever sees a reply -- merge/1 correctly
  # assumes already-normalized input, so testing raw {:text,_} data
  # against it directly tests the wrong boundary (confirmed: it fails,
  # not because merge/1 is wrong, but because that was never its job).

  test "returns an error immediately when the mesh pool isn't up, no timeout wait" do
    assert {:error, {:mesh_unavailable, _}} = ListBoardsOverMesh.call(50)
  end
end
