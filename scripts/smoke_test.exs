# Live boot smoke test -- the walking skeleton's real verification.
#
# eunit/exunit alone did not catch either real bug found while building
# this (a data_dir default mismatch, and an Elixir-binary-vs-Erlang-
# charlist trap in dets:open_file) -- both were wiring/type issues that
# only show up on a real boot against a real reckon-db store. This script
# is that boot, made reusable instead of a one-off `mix run -e` typed by
# hand. Mirrors hecate-tube's own smoke-test harness (see
# plans/PLAN_HECATE_WHITEBOARD_ROOT.md).
#
# Usage (from system/):
#   HECATE_DATA_DIR=/tmp/hecate-whiteboard-smoke mix run ../scripts/smoke_test.exs

IO.puts("--- dispatching initiate_board ---")

result =
  GuideBoardLifecycle.InitiateBoard.MaybeInitiateBoard.dispatch(%{
    owner: "raf",
    title: "walking skeleton smoke test"
  })

IO.inspect(result, label: "initiate_board result")

case result do
  {:ok, board_id, _version, _events} ->
    IO.puts("--- dispatching archive_board for #{board_id} ---")

    archive_result = GuideBoardLifecycle.ArchiveBoard.MaybeArchiveBoard.dispatch(%{board_id: board_id})
    IO.inspect(archive_result, label: "archive_board result")

    IO.puts("--- dispatching a second archive_board (must error: already_archived) ---")
    second = GuideBoardLifecycle.ArchiveBoard.MaybeArchiveBoard.dispatch(%{board_id: board_id})
    IO.inspect(second, label: "second archive_board result")

    case {archive_result, second} do
      {{:ok, _, _}, {:error, :already_archived}} ->
        IO.puts("--- smoke test PASSED ---")

      _ ->
        IO.puts("--- smoke test FAILED: unexpected results above ---")
        System.halt(1)
    end

  {:error, _} ->
    IO.puts("--- smoke test FAILED: initiate_board did not succeed ---")
    System.halt(1)
end
