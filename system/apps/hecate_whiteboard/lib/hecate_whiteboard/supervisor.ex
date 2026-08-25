defmodule HecateWhiteboard.Supervisor do
  # This service's own supervision tree, started by HecateWhiteboard.Service
  # after hecate_om has wired mesh/identity/health and (since store_id/0 +
  # data_dir/0 are exported) reckon-db + the evoq subscription.
  #
  # No children yet -- the walking skeleton only proves boot, mesh join, and
  # dispatching initiate_board/archive_board (guide_board_lifecycle boots as
  # its own sibling OTP app; evoq's aggregate registry starts board_aggregate
  # processes on demand, nothing to supervise here). host_board's mesh
  # providers and the LiveView web app are later phases.
  @moduledoc false

  use Supervisor

  def start_link, do: Supervisor.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init([]), do: Supervisor.init([], strategy: :one_for_one)
end
