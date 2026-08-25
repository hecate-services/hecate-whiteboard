defmodule QueryBoards.MixProject do
  use Mix.Project

  def project do
    [
      app: :query_boards,
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
      mod: {QueryBoards.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    # Reads the same ETS tables project_boards owns -- only umbrella dep
    # needed is for the table-name atoms, not for calling any of its code.
    [{:project_boards, in_umbrella: true}]
  end
end
