defmodule QueryBoards.Application do
  # AnswerBoardSnapshotQueriesStarter is join_board's host-side responder
  # (see that module) -- everything else this app exposes is a plain
  # function call (GetBoardSnapshotById, ListHostedBoards), no process
  # needed. Mirrors ProjectBoards.Supervisor's DynamicSupervisor +
  # Starter shape exactly.
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {DynamicSupervisor, name: QueryBoards.MeshSubscriberSupervisor, strategy: :one_for_one},
      QueryBoards.AnswerBoardSnapshotQueriesStarter
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: QueryBoards.Supervisor)
  end
end
