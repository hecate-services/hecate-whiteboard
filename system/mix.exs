defmodule HecateWhiteboardUmbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  defp releases do
    [
      hecate_whiteboard: [
        # Every app in the umbrella must be listed explicitly here --
        # `mix release` does NOT auto-include the rest just because
        # they're present under apps/. Adding a new umbrella app and
        # forgetting to add it here compiles fine and boots fine (`mix
        # phx.server`/`mix run` don't have this restriction), then
        # silently excludes it from the actual release with no error --
        # found the hard way when hecate_whiteboard_web's Endpoint never
        # started inside the built container, despite working locally.
        applications: [
          hecate_whiteboard: :permanent,
          guide_board_lifecycle: :permanent,
          project_boards: :permanent,
          query_boards: :permanent,
          track_presence: :permanent,
          hecate_whiteboard_web: :permanent
        ]
      ]
    ]
  end

  # Dependencies listed here are available only for this
  # project and cannot be accessed from applications inside
  # the apps folder.
  #
  # Run "mix help deps" for examples and options.
  defp deps do
    []
  end
end
