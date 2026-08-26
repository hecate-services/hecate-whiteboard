defmodule QueryBoards.GetBoardSnapshotByIdOverMeshTest do
  # The actual mesh round trip (query publish -> AnswerBoardSnapshotQueries
  # reply -> materialize) can only be exercised against a live pool -- this
  # dev/test sandbox genuinely cannot reach the mesh (same limitation noted
  # for ShapeLifecycleMeshSubscriber's own live verification). What's testable here
  # without one: the short-circuit when hecate_om has no pool yet.
  use ExUnit.Case, async: false

  alias QueryBoards.GetBoardSnapshotByIdOverMesh.GetBoardSnapshotByIdOverMesh

  test "returns an error immediately when the mesh pool isn't up, no timeout wait" do
    assert {:error, {:mesh_unavailable, _}} =
             GetBoardSnapshotByIdOverMesh.call("board-nonexistent", 50)
  end

  # Regression for a real bug found live 2026-08-25: normalize_shape/1 was
  # normalize_stroke/1, extracting only stroke_id/points/color/width --
  # correct back when a snapshot's `shapes` list held nothing but strokes,
  # silently wrong once sticky/text/geometry shapes existed. Every
  # non-stroke shape lost its kind/shape_id/text (replaced with a
  # stroke_id that never existed for it, always nil). Now that
  # shape_initiated_v1 unified shape creation, no row carries a
  # `stroke_id` field at all -- normalize_shape/1 no longer produces one.
  describe "normalize_shape/1" do
    test "a stroke keeps its own fields" do
      stroke = %{
        kind: "stroke",
        shape_id: "s1",
        points: [%{x: 1, y: 2}],
        color: "#f2efe6",
        width: 3
      }

      assert GetBoardSnapshotByIdOverMesh.normalize_shape(stroke) == %{
               kind: "stroke",
               shape_id: "s1",
               points: [%{x: 1, y: 2}],
               color: "#f2efe6",
               width: 3,
               text: nil,
               from_shape_id: nil,
               to_shape_id: nil
             }
    end

    test "a sticky keeps its kind, shape_id, and text -- the exact fields the bug dropped" do
      sticky = %{
        kind: "sticky",
        shape_id: "sticky1",
        points: [%{x: 84, y: 178}],
        color: "#f2994a",
        text: "video_viewed"
      }

      assert GetBoardSnapshotByIdOverMesh.normalize_shape(sticky) == %{
               kind: "sticky",
               shape_id: "sticky1",
               points: [%{x: 84, y: 178}],
               color: "#f2994a",
               width: nil,
               text: "video_viewed",
               from_shape_id: nil,
               to_shape_id: nil
             }
    end

    test "a rectangle keeps its kind and shape_id" do
      rectangle = %{
        kind: "rectangle",
        shape_id: "rect1",
        points: [%{x: 53, y: 39}, %{x: 280, y: 110}],
        color: "#f2efe6"
      }

      assert GetBoardSnapshotByIdOverMesh.normalize_shape(rectangle) == %{
               kind: "rectangle",
               shape_id: "rect1",
               points: [%{x: 53, y: 39}, %{x: 280, y: 110}],
               color: "#f2efe6",
               width: nil,
               text: nil,
               from_shape_id: nil,
               to_shape_id: nil
             }
    end

    # normalize_shape/1's own field/2 fallback (atom-or-string key) is
    # its real scope here -- {:text, _}-tag stripping happens one level
    # up, in the recursive normalize/1 that runs on the whole reply
    # before materialize/1 (and normalize_shape/1) ever see it.
    test "falls back to string keys, its own field/2's job" do
      sticky = %{
        "kind" => "sticky",
        "shape_id" => "sticky2",
        "points" => [%{x: 10, y: 20}],
        "color" => "#f2994a",
        "text" => "hello"
      }

      assert GetBoardSnapshotByIdOverMesh.normalize_shape(sticky) == %{
               kind: "sticky",
               shape_id: "sticky2",
               points: [%{x: 10, y: 20}],
               color: "#f2994a",
               width: nil,
               text: "hello",
               from_shape_id: nil,
               to_shape_id: nil
             }
    end
  end

  # The other half of the original bug: Store.new_shape?/1 (previously
  # new_stroke?/1, keyed on stroke_id) rejected every non-stroke shape
  # after the FIRST one in a snapshot's list as an apparent redelivery,
  # since they all shared the same nil stroke_id. Keying on shape_id
  # (always present and always unique) fixes this by construction, but
  # this proves it against the exact multi-shape shape of a real
  # snapshot: a rectangle plus two stickies, none of them strokes.
  test "a mixed non-stroke snapshot survives the new_shape?/1 dedup filter intact" do
    on_exit(fn -> :ets.delete_all_objects(ProjectBoards.Store.board_shapes_seen_table()) end)

    shapes = [
      %{kind: "rectangle", shape_id: "r1", points: [%{x: 0, y: 0}], color: "#fff"},
      %{kind: "sticky", shape_id: "st1", points: [%{x: 1, y: 1}], color: "#f2994a", text: "a"},
      %{kind: "sticky", shape_id: "st2", points: [%{x: 2, y: 2}], color: "#bb6bd9", text: "b"}
    ]

    survivors =
      shapes
      |> Enum.map(&GetBoardSnapshotByIdOverMesh.normalize_shape/1)
      |> Enum.filter(&ProjectBoards.Store.new_shape?(&1.shape_id))

    assert Enum.map(survivors, & &1.shape_id) == ["r1", "st1", "st2"]
    assert Enum.map(survivors, & &1.kind) == ["rectangle", "sticky", "sticky"]
    assert Enum.map(survivors, & &1.text) == [nil, "a", "b"]
  end
end
