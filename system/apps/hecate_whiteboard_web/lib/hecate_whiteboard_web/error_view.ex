defmodule HecateWhiteboardWeb.ErrorView do
  # Phoenix falls back to this module by naming convention when no
  # :render_errors is configured (Phoenix.Endpoint.Supervisor.render_errors/1
  # strips ".Endpoint" off the Endpoint module and appends ".ErrorView") --
  # that default ships accepts: ~w(html) and layout: false, so this only
  # ever needs an html clause and gets no root layout around it.
  #
  # Without this module any unmatched route (a bad path, a stray favicon
  # request) crashed to a raw 500 instead of a clean 404/500 page -- found
  # 2026-08-25 checking the deployed fleet's health endpoint from the wrong
  # port. Self-contained page, same chalk-on-slate palette as the board
  # itself, so a crash still looks like this app.

  def render("404.html", _assigns), do: page("Nothing here", "This board doesn't exist.")

  def render("500.html", _assigns),
    do: page("Something broke", "The host hit an error. Try reloading.")

  def render(template, _assigns) do
    status = template |> String.split(".") |> List.first()
    page("Error #{status}", "Something went wrong.")
  end

  # {:safe, iodata} tells Phoenix.HTML this is already-rendered markup --
  # a plain string return here gets html-escaped whole (Plug.HTML.html_escape
  # on the entire page), which is what a first cut of this did: <!doctype
  # html> rendered as literal escaped text instead of a page. Confirmed by
  # booting locally and curling a bad route before trusting this.
  defp page(title, message), do: {:safe, page_html(title, message)}

  defp page_html(title, message) do
    """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>#{title} · hecate-whiteboard</title>
        <style>
          :root {
            --slate: #262a27;
            --slate-deep: #1b1e1c;
            --chalk: #f2efe6;
            --chalk-dim: rgba(242, 239, 230, 0.5);
            --amber: #d89b4a;
          }
          html, body {
            height: 100%;
            margin: 0;
            background: var(--slate);
            color: var(--chalk);
            font-family: system-ui, -apple-system, "Segoe UI", sans-serif;
            -webkit-font-smoothing: antialiased;
          }
          body {
            display: flex;
            align-items: center;
            justify-content: center;
          }
          .card {
            text-align: center;
            max-width: 28rem;
            padding: 2rem;
          }
          h1 {
            font-size: 1.25rem;
            font-weight: 600;
            margin: 0 0 0.5rem;
          }
          p {
            color: var(--chalk-dim);
            margin: 0 0 1.5rem;
          }
          a {
            display: inline-block;
            color: var(--slate-deep);
            background: var(--amber);
            text-decoration: none;
            font-size: 0.85rem;
            font-weight: 600;
            padding: 0.5rem 1rem;
            border-radius: 8px;
          }
        </style>
      </head>
      <body>
        <div class="card">
          <h1>#{title}</h1>
          <p>#{message}</p>
          <a href="/">Back to the board</a>
        </div>
      </body>
    </html>
    """
  end
end
