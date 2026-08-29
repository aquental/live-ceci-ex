defmodule LiveCeci.Router do
  @moduledoc """
  The whole HTTP surface: one WebSocket upgrade plus static files.

  `GET /` is served by the explicit route at the bottom, NOT by `Plug.Static`.
  `Plug.Static` has no `:index` option — the word does not appear in its source — so a
  request for `/` falls straight through it to `plug :match`. An audit called that route
  dead code shadowed by Static; it was not, and deleting it turned the front page into a
  404 that `router_test.exs` caught immediately. The option that implied otherwise is
  gone, and the test below now pins the behaviour rather than the reasoning.

  No Phoenix. The wire protocol here is raw binary PCM frames, which Phoenix Channels
  would only wrap in a JSON envelope — so Plug + `WebSockAdapter.upgrade/4` is both
  smaller and a closer match to what the app actually does.
  """

  use Plug.Router

  require Logger

  # Cheap, and none of it depends on the app being hardened. The page loads no third-party
  # anything — its own stylesheet is inline, its scripts are two same-origin files, and
  # the only network it opens is a WebSocket back here — so a policy this tight costs
  # nothing and turns a future mistake into a blocked request instead of a silent one.
  #
  # `worker-src` is what the AudioWorklet needs; `script-src` alone does not cover
  # addModule in every browser. `media-src blob:` is her voice, built as AudioBuffers.
  # TLS is deliberately absent: this binds to loopback, where terminating TLS in-process
  # would be ceremony rather than protection. A deployment that reaches the network needs
  # a proxy in front doing TLS and HSTS, and none of these headers substitute for that.
  @csp "default-src 'self'; script-src 'self'; worker-src 'self' blob:; " <>
         "style-src 'self' 'unsafe-inline'; media-src 'self' blob:; " <>
         "connect-src 'self' ws: wss:; img-src 'self' data:; " <>
         "base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

  plug :security_headers

  defp security_headers(conn, _opts) do
    conn
    |> put_resp_header("content-security-policy", @csp)
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("cross-origin-opener-policy", "same-origin")
  end

  # Cross-Site WebSocket Hijacking, closed. Without this, ANY page the developer visits
  # could open a session here — demonstrated, not theoretical: `Origin: https://evil.example`
  # was answered with 101 Switching Protocols. There are no cookies to steal, but every
  # session opened is billed against the API key, which is enough.
  #
  # Loopback origins are allowed on ANY port, deliberately. Bound to 127.0.0.1 the only
  # pages that can reach us are served from this machine, and pinning the port would fight
  # every ephemeral one — latency_bench.exs starts its own listener on whatever the OS
  # hands it. The gap that leaves is another local dev server on a different port, which
  # on a POC bound to loopback is a trade worth making and worth writing down.
  @loopback_hosts ~w(localhost 127.0.0.1 ::1 [::1])

  @doc false
  # Public so a test can reach it without a live socket.
  def origin_allowed?(origin) when is_binary(origin) do
    case URI.parse(origin) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        host in @loopback_hosts or origin in LiveCeci.config().allowed_origins

      _ ->
        false
    end
  end

  def origin_allowed?(_origin), do: false

  # There is deliberately no Plug.Static over priv/assets. It used to serve four mp3s to
  # the music player; with the tools operational, nothing in the browser fetches from
  # there any more — and what remains in that directory is ceci_persona.txt, the system
  # prompt, which only the compiler reads. An allowlist protecting one private file is
  # weaker than not routing to it at all.

  # main.js / pcm-processor.js. NOT index.html at "/" — Plug.Static has no :index option,
  # and passing one is silently ignored. The `get "/"` route below is what serves it.
  plug Plug.Static, at: "/", from: {:live_ceci, "priv/frontend"}

  plug :match
  plug :dispatch

  get "/ws" do
    case get_req_header(conn, "origin") do
      [origin] ->
        if origin_allowed?(origin) do
          conn
          |> WebSockAdapter.upgrade(LiveCeci.Socket, [],
            timeout: 60_000,
            max_frame_size: 1_000_000
          )
          |> halt()
        else
          Logger.warning("rejected /ws upgrade from origin #{inspect(origin)}")
          conn |> send_resp(403, "forbidden") |> halt()
        end

      _missing ->
        # A browser ALWAYS sends Origin on a WebSocket handshake, so an absent one is not
        # a browser. Rejected rather than waved through: "allow when absent" is the usual
        # way an origin check ends up decorative. Non-browser clients that belong here —
        # priv/spike/latency_bench.exs is the one — send an Origin of their own.
        Logger.warning("rejected /ws upgrade with no Origin header")
        conn |> send_resp(403, "forbidden") |> halt()
    end
  end

  get "/healthz", do: send_resp(conn, 200, "ok")

  # The mic batch size and the silence budget live in .env, but the code that applies
  # them runs in an AudioWorklet. This is the only channel between them. Nothing secret
  # goes here: the browser already knows every value on this line, because it is the one
  # enforcing it.
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

  # Reachable, despite what an audit concluded. See the moduledoc.
  get "/" do
    send_file(conn, 200, Path.join(:code.priv_dir(:live_ceci), "frontend/index.html"))
  end

  match _, do: send_resp(conn, 404, "not found")
end
