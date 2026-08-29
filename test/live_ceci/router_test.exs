defmodule LiveCeci.RouterTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  @opts LiveCeci.Router.init([])

  defp call(conn), do: LiveCeci.Router.call(conn, @opts)

  # The RFC6455 handshake headers WebSockAdapter validates before upgrading. "host" has to
  # go in directly: Plug.Conn.put_req_header/3 refuses it, but the validation reads the header.
  # A real ticket by default: the Origin tests are about Origin, and a missing ticket
  # would make them pass for the wrong reason.
  defp ws_conn(origin \\ "http://localhost:8000", ticket \\ :valid) do
    query =
      case ticket do
        :valid ->
          {:ok, t} = LiveCeci.Tickets.issue({127, 0, 0, 1})
          "?ticket=#{t}"

        :none ->
          ""

        other ->
          "?ticket=#{other}"
      end

    conn =
      conn(:get, "/ws" <> query)
      |> put_req_header("connection", "upgrade")
      |> put_req_header("upgrade", "websocket")
      |> put_req_header("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
      |> put_req_header("sec-websocket-version", "13")

    conn = if origin, do: put_req_header(conn, "origin", origin), else: conn
    %{conn | req_headers: [{"host", "localhost"} | conn.req_headers]}
  end

  describe "the ticket on /ws" do
    # The Origin check stops another SITE opening a session. It stops nothing that speaks
    # HTTP directly, because Origin is a header and a non-browser picks what it sends.
    # The ticket is the part that requires having asked first.

    test "an upgrade with no ticket is refused" do
      assert call(ws_conn("http://localhost:8000", :none)).status == 403
    end

    test "an invented ticket is refused" do
      assert call(ws_conn("http://localhost:8000", "not-a-real-ticket")).status == 403
    end

    test "a ticket works exactly once" do
      # The property that makes a leaked query string survivable. :ets.take/2 is what
      # makes it atomic, so two connections racing on one ticket cannot both win.
      {:ok, ticket} = LiveCeci.Tickets.issue({127, 0, 0, 1})

      refute call(ws_conn("http://localhost:8000", ticket)).status == 403
      assert call(ws_conn("http://localhost:8000", ticket)).status == 403
    end

    test "a ticket minted for another address is refused" do
      # Nearly free on loopback; it starts mattering the moment BIND_IP opens up, which
      # is exactly when nobody remembers to add it.
      {:ok, ticket} = LiveCeci.Tickets.issue({10, 0, 0, 7})

      assert call(ws_conn("http://localhost:8000", ticket)).status == 403
    end

    test "the mint endpoint is behind the same Origin check as the upgrade" do
      # An endpoint that mints what /ws demands is worth exactly the check in front of it.
      hostile = conn(:post, "/ws-ticket") |> put_req_header("origin", "https://evil.example")
      assert call(hostile).status == 403

      ok = conn(:post, "/ws-ticket") |> put_req_header("origin", "http://localhost:8000")
      conn = call(ok)
      assert conn.status == 200
      assert %{"ticket" => t} = Jason.decode!(conn.resp_body)
      assert byte_size(t) >= 40
    end

    test "minting with no Origin at all is refused" do
      assert call(conn(:post, "/ws-ticket")).status == 403
    end
  end

  describe "the Origin check on /ws" do
    # This route had no test at all — ws_conn/0 was defined and never called — which is
    # how an unauthenticated upgrade survived an audit that flagged it. There are no
    # cookies here to steal, but every session opened is billed against the API key.

    test "a page from another site cannot open a session" do
      # Demonstrated before the check existed: this exact request was answered with
      # 101 Switching Protocols.
      conn = call(ws_conn("https://evil.example"))

      assert conn.status == 403
      assert conn.resp_body == "forbidden"
    end

    test "no Origin header is rejected too" do
      # A browser always sends one on a WebSocket handshake, so an absent Origin is not a
      # browser. Waving those through is the usual way an origin check becomes decorative.
      conn = call(ws_conn(nil))

      assert conn.status == 403
    end

    test "the page this server serves is allowed" do
      # Not asserting 101: Plug.Test cannot complete a real upgrade. What matters is that
      # it did NOT take the 403 branch.
      refute call(ws_conn("http://localhost:8000")).status == 403
      refute call(ws_conn("http://127.0.0.1:8000")).status == 403
    end

    test "loopback is allowed on any port, because ephemeral ports exist" do
      # latency_bench.exs starts its own listener on whatever the OS hands it. Pinning the
      # port would fight that for no security gain while bound to 127.0.0.1.
      refute call(ws_conn("http://localhost:54321")).status == 403
    end

    test "a hostname that merely contains a loopback name is not loopback" do
      # The failure a naive String.contains?/2 would have: these are real, buyable domains.
      for hostile <- [
            "https://localhost.evil.example",
            "https://evil.example/localhost",
            "http://127.0.0.1.evil.example"
          ] do
        assert call(ws_conn(hostile)).status == 403, "#{hostile} was allowed"
      end
    end

    test "a garbage Origin is rejected, not a crash" do
      for junk <- ["", "not a uri", "file:///etc/passwd", "javascript:alert(1)"] do
        assert call(ws_conn(junk)).status == 403, "#{inspect(junk)} was allowed"
      end
    end
  end

  describe "plain routes" do
    test "/healthz answers ok" do
      conn = call(conn(:get, "/healthz"))

      assert conn.status == 200
      assert conn.resp_body == "ok"
    end

    # The only channel between FRAME_SAMPLES in .env and the AudioWorklet that applies
    # it. If this route stops answering, the browser silently keeps the built-in default
    # and the .env setting does nothing visible.
    test "/config.json hands the browser the mic batch size" do
      conn = call(conn(:get, "/config.json"))

      assert conn.status == 200
      assert ["application/json" <> _] = get_resp_header(conn, "content-type")

      assert %{"frameSamples" => frame, "silenceMs" => silence} = Jason.decode!(conn.resp_body)
      assert frame == LiveCeci.config().frame_samples
      assert silence == LiveCeci.config().silence_duration_ms
    end

    test "/config.json carries nothing but the knobs — no keys, no model names" do
      # It is world-readable and unauthenticated. Everything on it is something the
      # browser already knows, because the browser is what enforces it.
      assert Jason.decode!(call(conn(:get, "/config.json")).resp_body)
             |> Map.keys()
             |> Enum.sort() ==
               ["frameSamples", "silenceMs"]
    end

    test "no file in priv/frontend shadows a route" do
      # Plug.Static runs BEFORE plug :match, so a file that happens to share a route's
      # name silently wins. /config.json is the live example: the moduledoc claims the
      # route works "only because priv/frontend holds no file by this name", and nothing
      # was checking that claim.
      routes = ["config.json", "healthz", "ws"]
      files = Path.join(:code.priv_dir(:live_ceci), "frontend") |> File.ls!()

      for route <- routes do
        refute route in files,
               "priv/frontend/#{route} shadows the #{route} route — Plug.Static wins"
      end
    end

    test "the security headers are on every response" do
      # The page loads no third-party anything, so the policy can be this tight for free.
      conn = call(conn(:get, "/healthz"))

      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "default-src 'self'"
      # The AudioWorklet needs worker-src; script-src alone does not cover addModule.
      assert csp =~ "worker-src 'self' blob:"
      # Her voice is played from AudioBuffers.
      assert csp =~ "media-src 'self' blob:"
      # The socket back to us.
      assert csp =~ "connect-src 'self' ws: wss:"

      assert ["nosniff"] = get_resp_header(conn, "x-content-type-options")
      assert ["no-referrer"] = get_resp_header(conn, "referrer-policy")
    end

    test "an unknown path is a 404, not a crash" do
      conn = call(conn(:get, "/no-such-thing"))

      assert conn.status == 404
      assert conn.resp_body == "not found"
    end
  end

  describe "static files" do
    # Plug.Static has NO :index option — the word does not appear in its source — so a
    # request for "/" falls through it to plug :match and the explicit route. An audit
    # called that route dead code shadowed by Static and deleting it turned the front page
    # into a 404. This test is what caught it, and it pins the behaviour so the same
    # reasoning cannot be reached twice.
    test "/ serves the client" do
      conn = call(conn(:get, "/"))

      assert conn.status == 200
      assert conn.resp_body =~ "live-ceci"
    end

    # priv/assets is no longer routed at all. It used to serve four mp3s to the music
    # player behind an `only:` allowlist, because the same directory holds
    # ceci_persona.txt — the system prompt. With the tools operational, nothing in the
    # browser fetches from there, and not routing to a directory beats allowlisting
    # around the one file in it that must never ship.
    test "the persona prompt is not reachable over HTTP" do
      conn = call(conn(:get, "/assets/ceci_persona.txt"))

      assert conn.status == 404
      refute conn.resp_body =~ "operacional"
    end

    test "nothing under /assets is served any more, not even what used to be public" do
      for path <- ["/assets/tracks.json", "/assets/tracks/01-song.mp3"] do
        assert call(conn(:get, path)).status == 404
      end
    end
  end
end
