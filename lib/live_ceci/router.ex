defmodule LiveCeci.Router do
  @moduledoc """
  The whole HTTP surface: one WebSocket upgrade plus static files.

  No Phoenix. The wire protocol here is raw binary PCM frames, which Phoenix Channels
  would only wrap in a JSON envelope — so Plug + `WebSockAdapter.upgrade/4` is both
  smaller and a closer match to what the app actually does.
  """

  use Plug.Router

  # Mira's four dream-pop tracks and the catalogue the browser fetches. `only:` is an
  # allowlist, not a blocklist, because priv/assets also holds mira_persona.txt — the
  # system prompt, which only the compiler reads. Anything added here stays private
  # until it is named on this line.
  plug Plug.Static, at: "/assets", from: {:live_ceci, "priv/assets"}, only: ~w(tracks tracks.json)

  # index.html / main.js / pcm-processor.js
  plug Plug.Static, at: "/", from: {:live_ceci, "priv/frontend"}, index: ["index.html"]

  plug :match
  plug :dispatch

  get "/ws" do
    conn
    |> WebSockAdapter.upgrade(LiveCeci.Socket, [], timeout: 60_000, max_frame_size: 1_000_000)
    |> halt()
  end

  get "/healthz", do: send_resp(conn, 200, "ok")

  get "/" do
    send_file(conn, 200, Path.join(:code.priv_dir(:live_ceci), "frontend/index.html"))
  end

  match _, do: send_resp(conn, 404, "not found")
end
