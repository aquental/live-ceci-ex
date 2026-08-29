defmodule LiveCeci.RouterTest do
  use ExUnit.Case, async: true

  alias LiveCeci.EnvSandbox
  import Plug.Test
  import Plug.Conn

  @opts LiveCeci.Router.init([])

  defp call(conn), do: LiveCeci.Router.call(conn, @opts)

  # The RFC6455 handshake headers WebSockAdapter validates before upgrading. "host" has to
  # go in directly: Plug.Conn.put_req_header/3 refuses it, but the validation reads the header.
  # A real ticket by default: the Origin tests are about Origin, and a missing ticket
  # would make them pass for the wrong reason.
  #
  # Each call uses a UNIQUE client address. Tickets are address-bound and capped per
  # address, and a test that expects 403 from the Origin check never reaches the ticket —
  # `and` short-circuits — so it mints one and leaves it outstanding for its full TTL.
  # Sharing 127.0.0.1 across every test in this file exhausted that cap and made
  # unrelated assertions fail on some seeds. Unique addresses also model reality better:
  # these are supposed to be different clients.
  defp ws_conn(origin, ticket \\ :valid) do
    address = {127, 0, :rand.uniform(250), :rand.uniform(250)}

    query =
      case ticket do
        :valid ->
          {:ok, t} = LiveCeci.Tickets.issue(address)
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
    %{conn | req_headers: [{"host", "localhost"} | conn.req_headers], remote_ip: address}
  end

  # ws_conn/2 with an explicit ticket AND the address it was minted for.
  defp ticket_conn(ticket, address) do
    conn =
      conn(:get, "/ws?ticket=#{ticket}")
      |> put_req_header("connection", "upgrade")
      |> put_req_header("upgrade", "websocket")
      |> put_req_header("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
      |> put_req_header("sec-websocket-version", "13")
      |> put_req_header("origin", "http://localhost:8000")

    %{conn | req_headers: [{"host", "localhost"} | conn.req_headers], remote_ip: address}
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
      #
      # Uses the default :valid path twice with the SAME ticket string, which means the
      # address has to match too — hence the explicit conn rather than ws_conn/2.
      address = {127, 0, 9, 9}
      {:ok, ticket} = LiveCeci.Tickets.issue(address)

      refute call(ticket_conn(ticket, address)).status == 403
      assert call(ticket_conn(ticket, address)).status == 403
    end

    test "a ticket minted for another address is refused" do
      # Nearly free on loopback; it starts mattering the moment BIND_IP opens up, which
      # is exactly when nobody remembers to add it.
      {:ok, ticket} = LiveCeci.Tickets.issue({10, 0, 0, 7})

      assert call(ticket_conn(ticket, {127, 0, 5, 5})).status == 403
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

    test "userinfo does not smuggle a hostile origin past the host check" do
      # `http://evil.example@localhost` parses with host: "localhost", so a check that
      # reads only the host allowed it — verified true before the fix. No browser puts
      # userinfo in an Origin header, so anything that does is not a browser.
      assert call(ws_conn("http://evil.example@localhost:8000")).status == 403
      assert call(ws_conn("https://evil.example@127.0.0.1")).status == 403
      refute LiveCeci.Router.origin_allowed?("http://evil.example@localhost")
    end

    test "the host comparison is case-insensitive, as hostnames are" do
      # A false NEGATIVE, and the less obvious half of the same bug: this was refused.
      assert LiveCeci.Router.origin_allowed?("http://LOCALHOST:8000")
      assert LiveCeci.Router.origin_allowed?("http://LocalHost:8000")
      refute call(ws_conn("http://LOCALHOST:8000")).status == 403
    end

    test "a configured origin matches whichever way its default port is written" do
      # ALLOWED_ORIGINS entries used to be compared as raw strings, so an entry written
      # with the port did not match a browser that omits it — and browsers omit it.
      EnvSandbox.put_env(:allowed_origins, ["https://ceci.pro:443"])

      assert LiveCeci.Router.origin_allowed?("https://ceci.pro")
      assert LiveCeci.Router.origin_allowed?("https://CECI.PRO:443")
      refute LiveCeci.Router.origin_allowed?("http://ceci.pro")
      refute LiveCeci.Router.origin_allowed?("https://ceci.pro:8443")
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

    test "X-Forwarded-For is ignored while TRUSTED_PROXIES is empty" do
      # The default, and the safe one. Anyone can send this header; honouring it without
      # knowing who is in front of you replaces a wrong address with an attacker-chosen
      # one, and every per-address bound in the app is keyed on that address.
      #
      # Asserted rather than assumed: this is the one test in the file whose subject is
      # the EMPTY list, so a leaked put_env from a sibling would turn it into a test of
      # something else and fail with a confusing address mismatch instead of saying so.
      assert LiveCeci.config().trusted_proxies == []

      conn =
        conn(:get, "/healthz")
        |> put_req_header("x-forwarded-for", "203.0.113.7")
        |> Map.put(:remote_ip, {10, 0, 0, 1})
        |> call()

      assert conn.remote_ip == {10, 0, 0, 1}
    end

    test "a trusted proxy hands over the address it forwarded" do
      EnvSandbox.put_env(:trusted_proxies, [{10, 0, 0, 1}])

      conn =
        conn(:get, "/healthz")
        |> put_req_header("x-forwarded-for", "203.0.113.7")
        |> Map.put(:remote_ip, {10, 0, 0, 1})
        |> call()

      assert conn.remote_ip == {203, 0, 113, 7}
    end

    test "an untrusted peer cannot forge one, however many hops it claims" do
      EnvSandbox.put_env(:trusted_proxies, [{10, 0, 0, 1}])

      conn =
        conn(:get, "/healthz")
        |> put_req_header("x-forwarded-for", "1.2.3.4, 5.6.7.8")
        |> Map.put(:remote_ip, {192, 168, 1, 9})
        |> call()

      assert conn.remote_ip == {192, 168, 1, 9}
    end

    test "the walk stops at the first hop we did not put there" do
      # Two of ours at the right, the client's own claim further left. Everything left of
      # the last address we control was written by someone we cannot see.
      EnvSandbox.put_env(:trusted_proxies, [{10, 0, 0, 1}, {10, 0, 0, 2}])

      conn =
        conn(:get, "/healthz")
        |> put_req_header("x-forwarded-for", "198.51.100.4, 203.0.113.7, 10.0.0.2")
        |> Map.put(:remote_ip, {10, 0, 0, 1})
        |> call()

      assert conn.remote_ip == {203, 0, 113, 7}
    end

    test "junk in the header falls back to the peer rather than skipping past it" do
      # Skipping an unparseable entry would let a client insert one to push the walk a hop
      # further left, into a value it wrote itself.
      EnvSandbox.put_env(:trusted_proxies, [{10, 0, 0, 1}])

      conn =
        conn(:get, "/healthz")
        |> put_req_header("x-forwarded-for", "203.0.113.7, not-an-ip")
        |> Map.put(:remote_ip, {10, 0, 0, 1})
        |> call()

      assert conn.remote_ip == {10, 0, 0, 1}
    end

    test "an IPv4 client on a dual-stack listener matches an IPv4 TRUSTED_PROXIES entry" do
      # BIND_IP=:: gives a dual-stack listener and an IPv4 peer then arrives as an
      # IPv4-mapped IPv6 address — verified, 127.0.0.1 shows up as
      # {0, 0, 0, 0, 0, 65535, 32512, 1}. Nobody writes that in TRUSTED_PROXIES, and the
      # mismatch fails CLOSED: the header is ignored and every per-address cap silently
      # becomes a global one.
      EnvSandbox.put_env(:trusted_proxies, [{10, 0, 0, 1}])

      mapped = {0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001}

      conn =
        conn(:get, "/healthz")
        |> put_req_header("x-forwarded-for", "203.0.113.7")
        |> Map.put(:remote_ip, mapped)
        |> call()

      assert conn.remote_ip == {203, 0, 113, 7}
    end

    test "a forwarded address that arrives IPv4-mapped is normalised too" do
      EnvSandbox.put_env(:trusted_proxies, [{10, 0, 0, 1}])

      conn =
        conn(:get, "/healthz")
        |> put_req_header("x-forwarded-for", "::ffff:203.0.113.7")
        |> Map.put(:remote_ip, {10, 0, 0, 1})
        |> call()

      assert conn.remote_ip == {203, 0, 113, 7}
    end

    test "a trusted proxy that forwards nothing leaves the peer alone" do
      EnvSandbox.put_env(:trusted_proxies, [{10, 0, 0, 1}])

      conn = conn(:get, "/healthz") |> Map.put(:remote_ip, {10, 0, 0, 1}) |> call()

      assert conn.remote_ip == {10, 0, 0, 1}
    end

    test "an IPv6 host is bracketed, and a malformed one falls back to 'self' alone" do
      # Plug reports an IPv6 host without its brackets, so the naive interpolation built
      # `ws://::1` — not a URL, so the browser discards the whole directive and blocks the
      # socket. Only reachable with BIND_IP set to an IPv6 address.
      csp = fn host ->
        conn = %{conn(:get, "/healthz") | host: host, port: 8123} |> call()
        [value] = get_resp_header(conn, "content-security-policy")
        value
      end

      assert csp.("::1") =~ "ws://[::1]:8123"
      refute csp.("::1") =~ "ws://::1"
      # A Host with a semicolon would end the directive and start another one. There is no
      # legitimate host this rejects, so it falls back rather than being escaped.
      assert csp.("evil;script-src *") =~ "connect-src 'self'"
      refute csp.("evil;script-src *") =~ "ws://"
    end

    test "a bad ticket is refused before anything touches the Sessions singleton" do
      # The ordering a security audit corrected. An Origin header is trivial to forge from
      # anything that is not a browser, so with the capacity check first a flood of forged
      # upgrades queued on the one GenServer every legitimate upgrade waits behind — and
      # join/1 fails CLOSED, so the flood would have become "muitas conexões" with every
      # slot free.
      #
      # Asserted as the SHAPE of the route rather than by timing, which would measure the
      # machine: the ticket check has to appear before the capacity check in the source.
      source = File.read!("lib/live_ceci/router.ex")
      [_before, route] = String.split(source, ~s(get "/ws" do), parts: 2)
      [route, _after] = String.split(route, ~s(get "/healthz"), parts: 2)

      peek = :binary.match(route, "Tickets.valid?") |> elem(0)
      capacity = :binary.match(route, "Sessions.available?") |> elem(0)

      assert peek < capacity,
             "the capacity singleton is reachable before the ticket is checked"
    end

    test "the ticket survives a capacity refusal, and is spent on a real upgrade" do
      EnvSandbox.put_env(:max_sessions, 0)

      address = {127, 0, 200, :rand.uniform(250)}
      {:ok, ticket} = LiveCeci.Tickets.issue(address)

      assert call(ticket_conn(ticket, address)).status == 503
      # Still valid: refusing for capacity must not cost the user their ticket.
      assert LiveCeci.Tickets.valid?(ticket, address)
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
      # The socket back to us, and ONLY back to us. This used to read
      # `connect-src 'self' ws: wss:`, where the bare schemes match any host — a script
      # that got onto this page could have streamed the microphone anywhere. Every source
      # now names this request's own host.
      assert csp =~ "connect-src 'self' ws://www.example.com wss://www.example.com "
      assert csp =~ "ws://www.example.com:80 wss://www.example.com:80"
      refute csp =~ "ws: "
      refute csp =~ "wss:;"

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
