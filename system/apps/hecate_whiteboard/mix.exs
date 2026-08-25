defmodule HecateWhiteboard.MixProject do
  use Mix.Project

  def project do
    [
      app: :hecate_whiteboard,
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
      mod: {HecateWhiteboard.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Pinned to what hex.pm actually has published, not hecate-om's local
      # .app.src (which reads 0.15.0 there but is unpublished) -- see
      # plans/PLAN_HECATE_WHITEBOARD_ROOT.md's hard-won-facts section.
      {:hecate_om, "~> 0.14.2"}
    ]
  end
end
