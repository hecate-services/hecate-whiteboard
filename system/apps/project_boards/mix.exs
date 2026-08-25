defmodule ProjectBoards.MixProject do
  use Mix.Project

  def project do
    [
      app: :project_boards,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {ProjectBoards.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:evoq, "~> 1.23"},
      # Not the full Phoenix framework -- just the pubsub library, so this
      # PRJ app can broadcast live writes without depending on the web app.
      # LiveViews subscribe and react; they never call this app directly.
      # See macula-io/CLAUDE.md's "Phoenix LiveView Architecture" rule.
      {:phoenix_pubsub, "~> 2.3"}
    ]
  end
end
