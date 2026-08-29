defmodule LiveCeci.RouterTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  @opts LiveCeci.Router.init([])

  defp call(conn), do: LiveCeci.Router.call(conn, @opts)

  # The RFC6455 handshake headers WebSockAdapter validates before upgrading. "host" has to
  # go in directly: Plug.Conn.put_req_header/3 refuses it, but the validation reads the header.
  defp ws_conn do
    conn =
      conn(:get, "/ws")
      |> put_req_header("connection", "upgrade")
      |> put_req_header("upgrade", "websocket")
      |> put_req_header("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
      |> put_req_header("sec-websocket-version", "13")

    %{conn | req_headers: [{"host", "localhost"} | conn.req_headers]}
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

      assert %{"frameSamples" => frame} = Jason.decode!(conn.resp_body)
      assert frame == LiveCeci.config().frame_samples
    end

    test "/config.json carries nothing but the knob — no keys, no model names" do
      # It is world-readable and unauthenticated. Everything on it is something the
      # browser already knows, because the browser is what enforces it.
      assert Jason.decode!(call(conn(:get, "/config.json")).resp_body) |> Map.keys() ==
               ["frameSamples"]
    end

    test "an unknown path is a 404, not a crash" do
      conn = call(conn(:get, "/no-such-thing"))

      assert conn.status == 404
      assert conn.resp_body == "not found"
    end
  end

  describe "static files" do
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
