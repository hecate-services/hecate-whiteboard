# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
#
# Note that all applications in your umbrella share the
# same configuration and dependencies, which is why they
# all use the same configuration file. If you want different
# configurations or dependencies per app, it is best to
# move said applications out of the umbrella.
import Config

config :logger, :console, format: "$date $time [$level] $message\n"

config :phoenix, :json_library, Jason

config :hecate_whiteboard_web, HecateWhiteboardWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  pubsub_server: HecateWhiteboardWeb.PubSub,
  live_view: [signing_salt: "hwb_live_view_salt"],
  # No fronting domain yet -- this is reached directly at
  # beam01.lab:PORT/beam02.lab:PORT (or localhost in dev), so there's no
  # single fixed :url host to check the socket's Origin against.
  # check_origin: false is a deliberate simplification for this
  # walking-skeleton phase (single-user tool, no auth/multi-tenancy yet),
  # not an oversight -- revisit once this sits behind a real host/domain.
  check_origin: false

# NODE_PATH=deps lets esbuild resolve bare `import "phoenix"` /
# `import "phoenix_live_view"` against the Hex deps' own package.json
# (each ships priv/static/*.mjs) -- confirmed present at
# deps/phoenix/package.json and deps/phoenix_live_view/package.json,
# no npm install needed for those two.
config :esbuild,
  version: "0.25.0",
  hecate_whiteboard_web: [
    args: ~w(js/app.js --bundle --target=es2022 --outfile=../priv/static/assets/app.js),
    cd: Path.expand("../apps/hecate_whiteboard_web/assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ],
  # Plain CSS, no Sass/Tailwind -- esbuild bundling it too just means one
  # build tool for both assets, not two.
  hecate_whiteboard_web_css: [
    args: ~w(css/app.css --bundle --outfile=../priv/static/assets/app.css),
    cd: Path.expand("../apps/hecate_whiteboard_web/assets", __DIR__)
  ]

# Everything else (hecate_om, evoq) is env-var-driven and identical in
# shape across dev/prod -- see config/runtime.exs, evaluated for both a
# local `iex -S mix` boot and a compiled release.
