import Config

# Evaluated on every boot -- a local `iex -S mix`/`mix run` and a compiled
# release both run this file, so one config shape covers dev and prod. The
# only difference between environments is which env vars are actually set;
# defaults below are dev-safe (writable local paths, a placeholder realm)
# so a laptop boot doesn't need real mesh secrets just to prove CMD/evoq
# wiring. Prod (the container) always sets every one of these for real --
# see infrastructure/scripts/docker-compose.hecate-whiteboard.yml in
# macula-demo.
data_dir = System.get_env("HECATE_DATA_DIR", "/tmp/hecate-whiteboard-dev")
health_port = String.to_integer(System.get_env("HECATE_HEALTH_PORT", "8490"))
realm = System.get_env("HECATE_REALM", String.duplicate("0", 64))

config :hecate_om,
  # Charlists, not Elixir binaries -- these are file paths, and this stack's
  # underlying dets/ra layer rejects a binary `file` option with {badarg,
  # ...} (confirmed directly: dets:open_file(x, [{file, <<"...">>}, ...])
  # raises; the charlist form works). See HecateWhiteboard.Service.data_dir/0
  # for the same fix and fuller explanation -- found there first, applied
  # here on the same reasoning since these are the same class of value.
  service_cert_path: ~c"/etc/hecate/secrets/service-cert.pem",
  station_socket: ~c"/run/macula/station.sock",
  health_port: health_port,
  capability_topic: "_mesh.cap.",
  # A self-generated peering identity, not an operator-provisioned
  # credential -- lands under the same persistent volume board_store lives
  # on. See hecate-tube's own sys.config.src for why this path matters
  # (hecate_om >= 0.14.1 self-heals a missing keypair here on first boot,
  # but only once a path is actually configured).
  identity_key_path: String.to_charlist(Path.join([data_dir, "identity", "keypair.erl.bin"])),
  realm: realm

# MANDATORY because HecateWhiteboard.Service exports store_id/0.
# hecate_om:boot/1 starts the store AND a per-store evoq subscription,
# which crashes on {not_configured, event_store_adapter} if this block is
# absent -- see hecate_om_store's own module header.
config :evoq,
  event_store_adapter: :reckon_evoq_adapter,
  subscription_adapter: :reckon_evoq_adapter,
  snapshot_store_adapter: :reckon_evoq_adapter,
  store_id: :board_store
