defmodule LiveDJ.RouterTest do
  # async: false — the SOCKET_HANDLER tests mutate :live_dj application env, which
  # LiveDJ.Router reads at request time and every other process shares.
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @opts LiveDJ.Router.init([])

  defp call(conn), do: LiveDJ.Router.call(conn, @opts)

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
      assert conn.resp_body =~ "live-dj"
    end

    test "the browser can fetch the track catalogue it drives the player from" do
      conn = call(conn(:get, "/assets/tracks.json"))

      assert conn.status == 200
      assert [%{"title" => _, "file" => _} | _] = Jason.decode!(conn.resp_body)
    end
  end

  describe "/ws upgrade" do
    test "upgrades to the configured socket handler with the framing limits" do
      call(ws_conn())

      assert_receive {_ref, :upgrade, {:websocket, {LiveDJ.Socket, [], opts}}}
      assert opts[:timeout] == 60_000
      assert opts[:max_frame_size] == 1_000_000
    end

    test "SOCKET_HANDLER=minimal swaps the handler without a recompile" do
      previous = Application.get_env(:live_dj, :socket_handler)
      Application.put_env(:live_dj, :socket_handler, LiveDJ.Minimal)
      on_exit(fn -> Application.put_env(:live_dj, :socket_handler, previous) end)

      call(ws_conn())

      assert_receive {_ref, :upgrade, {:websocket, {LiveDJ.Minimal, _, _}}}
    end

    test "the handler is resolved per request, not captured at init" do
      previous = Application.get_env(:live_dj, :socket_handler)
      on_exit(fn -> Application.put_env(:live_dj, :socket_handler, previous) end)

      # @opts was built once, above — proving the swap is read at call time.
      Application.put_env(:live_dj, :socket_handler, LiveDJ.Minimal)
      call(ws_conn())
      assert_receive {_ref, :upgrade, {:websocket, {LiveDJ.Minimal, _, _}}}

      Application.put_env(:live_dj, :socket_handler, LiveDJ.Socket)
      call(ws_conn())
      assert_receive {_ref, :upgrade, {:websocket, {LiveDJ.Socket, _, _}}}
    end
  end
end
