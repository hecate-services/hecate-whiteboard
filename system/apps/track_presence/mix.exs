defmodule TrackPresence.MixProject do
  use Mix.Project

  def project do
    [
      app: :track_presence,
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

  def application do
    [
      extra_applications: [:logger],
      mod: {TrackPresence.Application, []}
    ]
  end

  defp deps do
    [
      # Only for the umbrella boot-order guarantee: project_boards' own
      # Supervisor starts HecateWhiteboardWeb.PubSub as its first child
      # (see that module's own comment on why), and this app broadcasts
      # to that same registry -- depending on project_boards makes this
      # app start strictly after it, so the registry always exists by the
      # time Roster's first touch/1 call needs it. No code from
      # project_boards is actually called.
      {:project_boards, in_umbrella: true},
      {:phoenix_pubsub, "~> 2.3"},
      {:hecate_om, "~> 0.14.2"},
      {:macula, "~> 10.1"}
    ]
  end
end
