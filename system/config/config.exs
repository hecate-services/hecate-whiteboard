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

# Everything else (hecate_om, evoq) is env-var-driven and identical in
# shape across dev/prod -- see config/runtime.exs, evaluated for both a
# local `iex -S mix` boot and a compiled release.
