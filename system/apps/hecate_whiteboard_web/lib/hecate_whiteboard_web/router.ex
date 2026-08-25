defmodule HecateWhiteboardWeb.Router do
  use Phoenix.Router

  import Plug.Conn
  import Phoenix.Controller
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(:put_root_layout, html: {HecateWhiteboardWeb.Layouts, :root})
  end

  scope "/", HecateWhiteboardWeb do
    pipe_through(:browser)

    live("/", BoardLive)
    # join_board: a specific board_id, not necessarily hosted on THIS
    # node -- BoardLive's mount/3 tells the two apart. "/" keeps its
    # existing behaviour (the fixed default board, auto-hosted) untouched.
    live("/board/:board_id", BoardLive)
    # The picker: every board this node hosts, plus a form to start a
    # new one. See BoardsLive's own header for why it doesn't also try
    # to surface boards other peers host.
    live("/boards", BoardsLive)
  end
end
