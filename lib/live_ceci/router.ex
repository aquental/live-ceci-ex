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

  alias LiveCeci.Redact

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
  @csp_base "default-src 'self'; script-src 'self'; worker-src 'self' blob:; " <>
              "style-src 'self' 'unsafe-inline'; media-src 'self' blob:; " <>
              "img-src 'self' data:; " <>
              "base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

  # `connect-src` used to end `'self' ws: wss:`, which is not a restriction: the bare
  # schemes match ANY host, so a script that got onto this page could open a socket to
  # anywhere and stream the microphone out of it. Everything else in the policy was
  # tight and this one directive let it all out.
  #
  # It is pinned to this request's own host instead, four ways, and the redundancy is
  # deliberate:
  #
  #   * `'self'` is the correct answer and the only one that cannot be got wrong — the
  #     browser resolves it against the page's real origin. CSP Level 3 makes it cover
  #     ws/wss on that origin, but the browsers that implement that are a narrower set
  #     than the browsers that run an AudioWorklet, so it cannot be the only source.
  #   * `ws://host:port` is what an older browser matches, using the port this request
  #     arrived on.
  #   * `ws://host` with no port is what saves a deployment behind a TLS-terminating
  #     proxy. There, `Host:` says `example.com`, Bandit reports port 80 because it never
  #     saw the TLS, and the page — served over https — opens `wss://example.com` on 443.
  #     A port-less source takes the default port for ITS OWN scheme, so wss matches 443
  #     and the mismatch never happens.
  #
  # All four name the same host, so the hole this closes stays closed whichever one the
  # browser uses.
  #
  # The Host header is attacker-controlled, which matters here only because a value with
  # a `;` in it would end the directive and start another. A victim's browser sends the
  # real Host; an attacker setting a fake one only ever poisons the response to their own
  # request. Malformed hosts fall back to `'self'` alone rather than being escaped,
  # because there is no legitimate host this rejects.
  @host_chars ~r/^[A-Za-z0-9.\-:]+$/

  defp connect_src(conn) do
    if Regex.match?(@host_chars, conn.host) do
      host = bracket_ipv6(conn.host)

      "connect-src 'self' ws://#{host} wss://#{host} " <>
        "ws://#{host}:#{conn.port} wss://#{host}:#{conn.port}"
    else
      "connect-src 'self'"
    end
  end

  # Plug reports an IPv6 host WITHOUT its brackets — verified, `[::1]:8123` in the Host
  # header arrives as `"::1"` — and `ws://::1` is not a URL, so the whole directive would
  # be discarded and the socket blocked. Only reachable with BIND_IP set to an IPv6
  # address, which is exactly the deployment least likely to be tested by hand.
  defp bracket_ipv6(host) do
    if String.contains?(host, ":"), do: "[" <> host <> "]", else: host
  end

  plug :restore_client_address
  plug :security_headers

  # `conn.remote_ip` is the other end of the TCP connection, which behind a reverse proxy
  # is the proxy — every request in the world arriving from one address. That does not
  # weaken anything loudly; it weakens three things quietly. The ticket's address binding
  # becomes a tautology, `MAX_SESSIONS_PER_ADDRESS` becomes a global cap that would hold
  # the whole deployment to four concurrent users, and every rejection log names the
  # proxy.
  #
  # TRUSTED_PROXIES is empty by default, and while it is empty this plug does nothing at
  # all. `X-Forwarded-For` is a request header like any other — anyone can send one — so
  # trusting it without knowing who is in front of you replaces a wrong address with an
  # attacker-chosen one, which is worse: it would let a single client mint tickets under
  # as many identities as it cares to invent.
  defp restore_client_address(conn, _opts) do
    case LiveCeci.config().trusted_proxies do
      [] -> conn
      trusted -> %{conn | remote_ip: client_address(conn, trusted)}
    end
  end

  defp client_address(conn, trusted) do
    if unmap(conn.remote_ip) in trusted do
      conn
      |> get_req_header("x-forwarded-for")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&(&1 |> String.trim() |> parse_ip()))
      # Right to left, dropping proxies we put there ourselves. The first address that is
      # not one of ours is the closest thing to a client anybody can vouch for; everything
      # further left was written by whoever we cannot see and may be pure invention.
      |> Enum.reverse()
      |> Enum.drop_while(&(&1 in trusted))
      |> case do
        # An unparseable entry stops the walk and fails back to the peer. Skipping past it
        # would let a client insert junk to push the walk one hop further left, into a
        # value it wrote itself.
        [ip | _] when is_tuple(ip) -> ip
        _ -> conn.remote_ip
      end
    else
      conn.remote_ip
    end
  end

  defp parse_ip(text) do
    case :inet.parse_address(String.to_charlist(text)) do
      {:ok, address} -> unmap(address)
      {:error, _} -> :unparseable
    end
  end

  # `BIND_IP=::` gives a dual-stack listener, and an IPv4 client then arrives as an
  # IPv4-mapped IPv6 address — verified, 127.0.0.1 shows up as
  # {0, 0, 0, 0, 0, 65535, 32512, 1}. `TRUSTED_PROXIES=10.0.0.1` parses to a 4-tuple and
  # would never match it. That fails closed, which sounds fine and is not: the header is
  # then ignored, the per-address caps silently revert to global ones, and
  # MAX_SESSIONS_PER_ADDRESS quietly becomes the ceiling for the whole deployment.
  defp unmap({0, 0, 0, 0, 0, 0xFFFF, ab, cd}) do
    {Bitwise.bsr(ab, 8), Bitwise.band(ab, 0xFF), Bitwise.bsr(cd, 8), Bitwise.band(cd, 0xFF)}
  end

  defp unmap(address), do: address

  defp security_headers(conn, _opts) do
    conn
    |> put_resp_header("content-security-policy", @csp_base <> "; " <> connect_src(conn))
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
  #
  # No `[::1]` entry, however much an Origin header looks like it needs one:
  # `URI.parse/1` strips the brackets and reports the host as `::1`, so the bracketed
  # spelling was a row that could never match. It was there for two months.
  @loopback_hosts ~w(localhost 127.0.0.1 ::1)

  @doc false
  # Public so a test can reach it without a live socket.
  def origin_allowed?(origin) when is_binary(origin) do
    # `userinfo: nil` is load-bearing. Without it `http://evil.example@localhost` was
    # allowed, because URI.parse reports the host as `localhost` and the attacker's name
    # sits in a field nothing looked at. No browser puts userinfo in an Origin header, so
    # anything that does is not a browser and has nothing to lose by being refused.
    case URI.parse(origin) do
      %URI{scheme: scheme, host: host, userinfo: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        String.downcase(host) in @loopback_hosts or key(origin) in allowed_keys()

      _ ->
        false
    end
  end

  def origin_allowed?(_origin), do: false

  # Hostnames are case-insensitive and `https://x` and `https://x:443` are the same
  # origin, but the check used to be `origin in allowed_origins` — a raw string compare,
  # so `http://LOCALHOST:8000` was refused and an ALLOWED_ORIGINS entry written with a
  # default port did not match a browser that omits it. Comparing the parsed triple
  # settles both, on both sides of the comparison.
  defp key(origin) do
    case URI.parse(origin) do
      %URI{scheme: scheme, host: host, port: port} when is_binary(scheme) and is_binary(host) ->
        {String.downcase(scheme), String.downcase(host), port}

      _ ->
        :invalid
    end
  end

  defp allowed_keys, do: Enum.map(LiveCeci.config().allowed_origins, &key/1)

  # Single use and address-bound, both enforced in LiveCeci.Tickets. A missing ticket is
  # the same answer as a wrong one.
  defp ticket_ok?(conn) do
    LiveCeci.Tickets.consume(conn.query_params["ticket"], conn.remote_ip) == :ok
  end

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

  # The ticket is minted here, over ordinary HTTP, because the upgrade cannot carry a
  # credential: the browser's `new WebSocket(url)` takes no headers. Origin-checked like
  # /ws itself — an endpoint that mints the thing /ws demands is worth exactly as much as
  # the check in front of it.
  post "/ws-ticket" do
    with [origin] <- get_req_header(conn, "origin"),
         true <- origin_allowed?(origin),
         {:ok, ticket} <- LiveCeci.Tickets.issue(conn.remote_ip) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{ticket: ticket}))
      |> halt()
    else
      {:error, :too_many} ->
        conn |> send_resp(503, "too many outstanding tickets") |> halt()

      _rejected ->
        Logger.warning(
          "rejected /ws-ticket from origin #{Redact.inspect(get_req_header(conn, "origin"))}"
        )

        conn |> send_resp(403, "forbidden") |> halt()
    end
  end

  get "/ws" do
    conn = fetch_query_params(conn)

    case get_req_header(conn, "origin") do
      [origin] ->
        cond do
          not origin_allowed?(origin) ->
            Logger.warning("rejected /ws upgrade from origin #{Redact.inspect(origin)}")
            conn |> send_resp(403, "forbidden") |> halt()

          # Peeked, not spent, and asked BEFORE anything that touches a GenServer. The
          # capacity check used to come first, and a security audit was right about what
          # that meant: an `Origin` header is trivial to forge from anything that is not a
          # browser, so a flood of unauthenticated upgrades queued on the one process every
          # legitimate upgrade waits behind — and Sessions.join/1 fails CLOSED, so the
          # flood would have become "muitas conexões" with every slot free.
          #
          # One ETS lookup in the connection's own process, 0.45 µs, and it is the whole
          # reason the ordering can be fixed without burning the ticket on the 503 below.
          not LiveCeci.Tickets.valid?(conn.query_params["ticket"], conn.remote_ip) ->
            Logger.warning("rejected /ws upgrade: bad or missing ticket")
            conn |> send_resp(403, "forbidden") |> halt()

          # Asked BEFORE the ticket is spent. At capacity this is a plain 503 with the
          # ticket still valid, instead of consuming it and then answering a completed
          # handshake with a 1013 close. Advisory only — LiveCeci.Socket.init/1 still
          # makes the authoritative claim, and still refuses if this raced.
          # Yes, this is a second call to the Sessions singleton alongside join/1 in
          # Socket.init/1, and an audit flagged the duplication. Kept deliberately: the
          # pair is what preserves the ticket on a capacity refusal, and both calls
          # together cost roughly 12 µs against a connection setup that spends hundreds
          # of milliseconds opening the upstream session.
          not LiveCeci.Sessions.available?(conn.remote_ip) ->
            Logger.warning("refusing /ws upgrade at capacity")
            conn |> send_resp(503, "muitas conexões — tente daqui a pouco") |> halt()

          # And NOW it is spent. Between the peek above and here a racing connection can
          # take it, which is why this stays the authoritative check and still refuses.
          not ticket_ok?(conn) ->
            Logger.warning("rejected /ws upgrade: ticket taken between the peek and the spend")
            conn |> send_resp(403, "forbidden") |> halt()

          true ->
            conn
            |> WebSockAdapter.upgrade(LiveCeci.Socket, [address: conn.remote_ip],
              timeout: 60_000,
              max_frame_size: 1_000_000
            )
            |> halt()
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
