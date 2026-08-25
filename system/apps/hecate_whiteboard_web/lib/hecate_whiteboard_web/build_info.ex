defmodule HecateWhiteboardWeb.BuildInfo do
  # Cache-busting for /assets/app.js and app.css. Plug.Static's own
  # Cache-Control on this repo's plain esbuild output (no content-hashed
  # filename, unlike a full `mix phx.digest` pipeline) is just
  # `public` -- no max-age, no immutable, no Last-Modified -- so a
  # browser's heuristic freshness calculation can serve a stale bundle
  # indefinitely across a redeploy with no error, no console warning,
  # nothing: the page just silently keeps running yesterday's JS. Found
  # live 2026-08-25: a real user reported the toolbox tools doing nothing
  # right after a fix had already shipped and been verified server-side.
  #
  # Fixed by baking the git commit into the asset URL itself (?v=<sha>)
  # so a new deploy is always a genuinely new URL, forcing a real fetch
  # instead of relying on cache revalidation. Evaluated ONCE at compile
  # time (a module attribute, not a runtime System.get_env/2 call) so the
  # value survives into the release with no cross-stage ENV plumbing
  # needed between the Dockerfile's build and runtime stages -- see
  # GIT_SHA's own ARG/ENV declaration there, set right before `mix
  # compile` runs.
  @moduledoc false

  @asset_version System.get_env("GIT_SHA", "dev") |> String.slice(0, 12)

  def asset_version, do: @asset_version
end
