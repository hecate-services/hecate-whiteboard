defmodule HecateWhiteboardWeb.Application do
  # PubSub first (project_boards' projections broadcast to it by name),
  # then the Endpoint. LiveViews subscribe and react; they never call
  # project_boards/guide_board_lifecycle's modules directly except through
  # the query_boards desk and evoq dispatch calls made from BoardLive
  # itself -- see macula-io/CLAUDE.md's "Phoenix LiveView Architecture" rule.
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: HecateWhiteboardWeb.PubSub},
      HecateWhiteboardWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: HecateWhiteboardWeb.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    HecateWhiteboardWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
