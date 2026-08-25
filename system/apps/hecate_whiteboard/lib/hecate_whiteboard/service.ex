defmodule HecateWhiteboard.Service do
  # The hecate_om service contract: what this service is and may do.
  #
  # SIX CALLBACKS REQUIRED. hecate_om resolves them by name at startup, on a
  # live node, so a service that forgets one dies with `undef` where nobody
  # is watching. `@behaviour :hecate_om_service` turns that into a compile
  # error instead. First Elixir implementation of this behaviour anywhere in
  # this workspace -- see plans/PLAN_HECATE_WHITEBOARD_ROOT.md, risk #1.
  #
  # IT ANNOUNCES NOTHING AND ASKS FOR NOTHING BEYOND ITS OWN NAMESPACE, on
  # purpose -- mirrors hecate-tube's own walking skeleton. Both grow once
  # host_board/join_board exist to actually advertise/serve.
  @behaviour :hecate_om_service

  @impl true
  def info do
    %{
      name: "hecate-whiteboard",
      version: "0.1.0",
      description:
        "Real-time multi-user whiteboard over mesh -- host a board on your own node, no central server"
    }
  end

  @impl true
  def start(_opts), do: HecateWhiteboard.Supervisor.start_link()

  @impl true
  def stop(_state), do: :ok

  # Green once the supervision tree is up. A dark mesh is not a health
  # failure by default -- revisit once this service actually depends on
  # mesh reachability to do its job.
  @impl true
  def health, do: :ok

  @impl true
  def capabilities, do: []

  # The scope is claimed now because it is the namespace every later
  # resource (host_board, join_board RPC providers) hangs under, and a
  # scope costs nothing while a rename costs every deployed peer.
  @impl true
  def identity_spec do
    %{scope: "hecate-whiteboard", actions: [], resources: [], ttl_days: 30}
  end

  # CMD/PRJ wiring: exporting both callbacks makes hecate_om:boot/1 start
  # reckon-db + the evoq subscription before start/1 runs. Requires the
  # evoq adapter block in config/runtime.exs, or evoq dispatch crashes on
  # {not_configured, event_store_adapter}.
  @impl true
  def store_id, do: :board_store

  # Same env var and same default as config/runtime.exs's identity_key_path
  # computation -- two independent reads of HECATE_DATA_DIR, so they must
  # agree or dev boot breaks (this one hard-coded /var/lib/hecate-whiteboard
  # at first, unwritable locally, while runtime.exs used a /tmp dev
  # default -- caught by the walking-skeleton smoke test).
  #
  # MUST be a charlist, not an Elixir binary. The behaviour's -callback
  # spec says string() -- Erlang's string() means [char()], not binary().
  # An Elixir binary here survives filename:join/2 (which happily returns
  # a binary) but then crashes deep inside ra's directory setup with
  # dets:open_file/2 {badarg, ...} on the `file` option, since dets there
  # rejects a binary path outright. Confirmed directly against this OTP:
  # dets:open_file(x, [{file, <<"...">>}, ...]) raises badarg;
  # dets:open_file(x, [{file, "..."}, ...]) works. hecate-tube's own
  # Erlang code never hit this because os:getenv/2 already returns a
  # charlist.
  @impl true
  def data_dir,
    do: String.to_charlist(System.get_env("HECATE_DATA_DIR", "/tmp/hecate-whiteboard-dev"))
end
