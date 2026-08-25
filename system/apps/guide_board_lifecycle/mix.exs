defmodule GuideBoardLifecycle.MixProject do
  use Mix.Project

  def project do
    [
      app: :guide_board_lifecycle,
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
      mod: {GuideBoardLifecycle.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:evoq, "~> 1.23"},
      # Declared directly (not just pulled in transitively via hecate_om) --
      # this app mints stream ids straight from its own command constructors,
      # mirroring hecate-tube's guide_tube_lifecycle.
      {:reckon_gater, "~> 3.11"},
      # For the stroke_drawn_v1_to_mesh emitter: :hecate_om.mesh_handles/0
      # and :macula_publisher directly, same reasoning as reckon_gater above.
      {:hecate_om, "~> 0.14.2"},
      {:macula, "~> 10.1"}
    ]
  end
end
