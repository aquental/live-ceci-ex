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

    test "the browser can fetch the track catalogue it drives the player from" do
      conn = call(conn(:get, "/assets/tracks.json"))

      assert conn.status == 200
      assert [%{"title" => _, "file" => _} | _] = Jason.decode!(conn.resp_body)
    end

    test "the audio files the player streams are still served" do
      conn = call(conn(:get, "/assets/tracks/01-song.mp3"))

      assert conn.status == 200
    end

    # priv/assets mixes two audiences: media the browser fetches, and ceci_persona.txt,
    # which only the compiler reads (LiveCeci.Persona inlines it via @external_resource).
    # Plug.Static cannot tell them apart on its own, so the allowlist is what keeps the
    # system prompt off the wire.
    test "the persona prompt is not reachable over HTTP" do
      conn = call(conn(:get, "/assets/ceci_persona.txt"))

      assert conn.status == 404
      refute conn.resp_body =~ "midnight"
    end
  end

  describe "/ws upgrade" do
    test "upgrades to the socket handler with the framing limits" do
      call(ws_conn())

      assert_receive {_ref, :upgrade, {:websocket, {LiveCeci.Socket, [], opts}}}
      assert opts[:timeout] == 60_000
      assert opts[:max_frame_size] == 1_000_000
    end
  end
end
