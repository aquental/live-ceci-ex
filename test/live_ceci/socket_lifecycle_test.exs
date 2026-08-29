defmodule LiveCeci.SocketLifecycleTest do
  @moduledoc """
  `init/1` and `terminate/2`, which the rest of `socket_test.exs` cannot reach:
  `init/1` resolves the provider through application env, so these have to run
  serially.

  This is where the error path of the security fix lives. `error_frame/1` has two
  call sites — a failing `handle_info` and a failing `init/1` — and only the first
  was covered.
  """
  use ExUnit.Case, async: false

  alias LiveCeci.Socket

  defmodule OkProvider do
    @behaviour LiveCeci.Provider
    # Reports synchronously: sending from inside the spawned process races the test.
    def open(opts) do
      send(Keyword.fetch!(opts, :owner), {:opened, opts})
      {:ok, spawn(fn -> Process.sleep(:infinity) end)}
    end

    def send_audio(_s, _pcm), do: :ok
    def close(session), do: send(self(), {:closed, session}) && :ok
  end

  defmodule FailProvider do
    @behaviour LiveCeci.Provider
    # A reason shaped like the real one: an upstream 403 carries the API key, because
    # gemini_ex puts it in the WebSocket URL.
    def open(_opts), do: {:error, {:http_error, 403, "API key not valid: AIzaSyFAKE"}}
    def send_audio(_s, _pcm), do: :ok
    def close(_s), do: :ok
  end

  defp with_provider(module) do
    previous = Application.get_env(:live_ceci, :provider)
    Application.put_env(:live_ceci, :provider, module)
    on_exit(fn -> Application.put_env(:live_ceci, :provider, previous) end)
  end

  describe "init/1 when the session opens" do
    setup do: with_provider(OkProvider)

    test "keeps the session and the provider that made it" do
      assert {:ok, %{session: session, provider: OkProvider}} = Socket.init([])
      assert is_pid(session)
    end

    test "passes the configured model, voice and language through" do
      assert {:ok, _state} = Socket.init([])
      config = LiveCeci.config()

      assert_received {:opened, opts}
      assert opts[:model] == config.model
      assert opts[:voice] == config.voice
      assert opts[:language] == config.language
      assert opts[:owner] == self()
    end
  end

  describe "init/1 when the session fails to open" do
    setup do: with_provider(FailProvider)

    test "stops instead of lingering with no session" do
      # A socket left alive with session: nil sends every later binary frame into the
      # no-op clause, and the browser's continuous mic traffic keeps resetting the
      # idle timeout — so it would never close on its own.
      assert {:stop, :normal, 1011, _frame, %{session: nil}} = Socket.init([])
    end

    test "the close frame does not leak the upstream reason" do
      assert {:stop, :normal, 1011, [{:text, json}], _state} = Socket.init([])

      refute json =~ "AIzaSyFAKE"
      refute json =~ "403"

      assert %{"type" => "error", "message" => "the line dropped — try again"} =
               Jason.decode!(json)
    end
  end

  describe "terminate/2" do
    test "closes the session through the provider that opened it" do
      session = spawn(fn -> :ok end)
      assert :ok = Socket.terminate(:normal, %{session: session, provider: OkProvider})
      assert_received {:closed, ^session}
    end

    test "a socket that never got a session has nothing to close" do
      assert :ok = Socket.terminate(:normal, %{session: nil, provider: OkProvider})
      refute_received {:closed, _}
    end
  end
end
