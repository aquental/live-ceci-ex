defmodule LiveCeci.Router do
  @moduledoc """
  The whole HTTP surface: one WebSocket upgrade plus static files.

  No Phoenix. The wire protocol here is raw binary PCM frames, which Phoenix Channels
  would only wrap in a JSON envelope — so Plug + `WebSockAdapter.upgrade/4` is both
  smaller and a closer match to what the app actually does.
  """

  use Plug.Router

  # There is deliberately no Plug.Static over priv/assets. It used to serve four mp3s to
  # the music player; with the tools operational, nothing in the browser fetches from
  # there any more — and what remains in that directory is ceci_persona.txt, the system
  # prompt, which only the compiler reads. An allowlist protecting one private file is
  # weaker than not routing to it at all.

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

  # The mic batch size and the silence budget live in .env, but the code that applies
  # them runs in an AudioWorklet. This is the only channel between them. Nothing secret goes here: the
  # browser already knows every value on this line, because it is the one enforcing it.
  #
  # Reachable only because priv/frontend holds no file by this name — the Plug.Static
  # above would shadow the route if one ever appeared.
  get "/config.json" do
    config = LiveCeci.config()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      200,
      Jason.encode!(%{frameSamples: config.frame_samples, silenceMs: config.silence_duration_ms})
    )
  end

  get "/" do
    send_file(conn, 200, Path.join(:code.priv_dir(:live_ceci), "frontend/index.html"))
  end

  match _, do: send_resp(conn, 404, "not found")
end
