defmodule HecateWhiteboardWeb.Application do
  # The HecateWhiteboardWeb.PubSub registry itself is started by
  # ProjectBoards, NOT here -- see that app's Supervisor for why. This
  # app only starts the Endpoint; LiveViews subscribe and react, they
  # never call project_boards/guide_board_lifecycle's modules directly
  # except through the query_boards desk and evoq dispatch calls made
  # from BoardLive itself -- see macula-io/CLAUDE.md's "Phoenix LiveView
  # Architecture" rule.
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [HecateWhiteboardWeb.Endpoint]
    Supervisor.start_link(children, strategy: :one_for_one, name: HecateWhiteboardWeb.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    HecateWhiteboardWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
