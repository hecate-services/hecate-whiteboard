defmodule HecateWhiteboardWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :hecate_whiteboard_web

  @session_options [
    store: :cookie,
    key: "_hecate_whiteboard_key",
    signing_salt: "hwb_session_salt",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  # No favicon.ico shipped yet -- listing it here without the file present
  # turned a browser's routine favicon request into a raw 500 (no
  # ErrorView fallback configured either). Leaving it out of `only` lets
  # that request 404 cleanly instead.
  plug(Plug.Static,
    at: "/",
    from: :hecate_whiteboard_web,
    gzip: false,
    only: ~w(assets)
  )

  plug(Plug.RequestId)
  plug(Plug.Session, @session_options)
  plug(HecateWhiteboardWeb.Router)
end
