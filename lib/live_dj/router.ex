defmodule LiveDJ.Router do
  @moduledoc """
  The whole HTTP surface: one WebSocket upgrade plus static files.

  No Phoenix. The wire protocol here is raw binary PCM frames, which Phoenix Channels
  would only wrap in a JSON envelope — so Plug + `WebSockAdapter.upgrade/4` is both
  smaller and a closer match to what the app actually does.
  """

  use Plug.Router

  # Mira's four dream-pop tracks and the catalogue the browser fetches.
  plug(Plug.Static, at: "/assets", from: {:live_dj, "priv/assets"})

  # index.html / main.js / pcm-processor.js
  plug(Plug.Static, at: "/", from: {:live_dj, "priv/frontend"}, index: ["index.html"])

  plug(:match)
  plug(:dispatch)

  get "/ws" do
    # Resolved at request time so SOCKET_HANDLER=minimal swaps in the stripped-down
    # bridge without a recompile.
    handler = Application.get_env(:live_dj, :socket_handler, LiveDJ.Socket)

    conn
    |> WebSockAdapter.upgrade(handler, [], timeout: 60_000, max_frame_size: 1_000_000)
    |> halt()
  end

  get("/healthz", do: send_resp(conn, 200, "ok"))

  get "/" do
    send_file(conn, 200, Path.join(:code.priv_dir(:live_dj), "frontend/index.html"))
  end

  match(_, do: send_resp(conn, 404, "not found"))
end
