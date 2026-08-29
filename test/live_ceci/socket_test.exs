defmodule LiveCeci.SocketTest do
  @moduledoc """
  The bridge, tested at the message-translation level: provider events in, real
  WebSocket frames out. No browser automation, no live session — the seam is
  `handle_info/2`, which is where every wire-contract bug the frontend can see
  actually lives.

  Nothing here mentions Gemini or Grok. That is the point: the socket sees only the
  neutral events in `LiveCeci.Provider`, and each provider's own translation is tested
  against its own wire format in `test/live_ceci/provider/`.
  """
  use ExUnit.Case, async: true

  alias LiveCeci.Socket

  @pcm <<1, 0, 2, 0, 3, 0, 255, 127>>

  defp state, do: %{session: nil, provider: LiveCeci.Provider.Gemini}

  describe "voice downstream" do
    test "voice is pushed as a binary frame, unchanged" do
      assert {:push, [{:binary, pcm}], _state} =
               Socket.handle_info({:provider, {:voice, @pcm}}, state())

      assert pcm == @pcm
    end

    test "each voice event is its own frame, so ordering is the mailbox's ordering" do
      assert {:push, [{:binary, <<1, 0>>}], s1} =
               Socket.handle_info({:provider, {:voice, <<1, 0>>}}, state())

      assert {:push, [{:binary, <<2, 0>>}], _s2} =
               Socket.handle_info({:provider, {:voice, <<2, 0>>}}, s1)
    end
  end

  describe "barge-in" do
    test "interrupted becomes the JSON the frontend cuts playback on" do
      assert {:push, [{:text, json}], _state} =
               Socket.handle_info({:provider, :interrupted}, state())

      assert Jason.decode!(json) == %{"type" => "interrupted"}
    end
  end

  describe "transcripts" do
    test "a user transcript is labelled as the user" do
      assert {:push, [{:text, json}], _state} =
               Socket.handle_info({:provider, {:transcript, :user, "play something"}}, state())

      assert %{"type" => "transcript", "role" => "user", "text" => "play something"} =
               Jason.decode!(json)
    end

    test "a model transcript is labelled as ceci" do
      assert {:push, [{:text, json}], _state} =
               Socket.handle_info({:provider, {:transcript, :ceci, "sure"}}, state())

      assert %{"type" => "transcript", "role" => "ceci", "text" => "sure"} = Jason.decode!(json)
    end
  end

  describe "end of speech" do
    test "the browser's turn signal reaches the provider" do
      # In manual mode the client's gate decides your sentence ended. This is the only
      # text frame the frontend sends, and this is the whole path it travels.
      defmodule CommitStub do
        @behaviour LiveCeci.Provider
        def open(_opts), do: {:error, :unused}
        def send_audio(_s, _pcm), do: :ok
        def close(_s), do: :ok
        def commit_turn(owner), do: send(owner, :committed) && :ok
      end

      state = %{session: self(), provider: CommitStub}
      frame = Jason.encode!(%{type: "end_of_speech"})

      assert {:ok, ^state} = Socket.handle_in({frame, [opcode: :text]}, state)
      assert_received :committed
    end

    test "an unknown or malformed text frame is ignored, not a crash" do
      # The browser is untrusted. Anything that is not the one frame we defined must be
      # dropped without taking the call down.
      state = %{session: self(), provider: LiveCeci.Provider.Grok}

      for junk <- [~s({"type":"teleport"}), "not json at all", "", "[]"] do
        assert {:ok, ^state} = Socket.handle_in({junk, [opcode: :text]}, state)
      end

      refute_received {:"$websockex_cast", _}
    end
  end

  describe "tool commands" do
    test "the action reaches the browser as the frontend's action message" do
      assert {:push, [{:text, json}], _state} =
               Socket.handle_info(
                 {:provider, {:action, %{action: "recibo", detail: "M.S. · R$ 250"}}},
                 state()
               )

      assert %{"type" => "action", "action" => "recibo", "detail" => "M.S. · R$ 250"} =
               Jason.decode!(json)
    end
  end

  describe "failure paths" do
    test "a session error is reported to the browser instead of dying silently" do
      assert {:push, [{:text, json}], _state} =
               Socket.handle_info({:provider, {:error, :boom}}, state())

      assert %{"type" => "error", "message" => message} = Jason.decode!(json)
      assert message == "a linha caiu — tente de novo"
    end

    test "the error frame does not leak the upstream reason to the browser" do
      reason = {:http_error, 403, "API key not valid: AIzaSyFAKE"}

      assert {:push, [{:text, json}], _state} =
               Socket.handle_info({:provider, {:error, reason}}, state())

      refute json =~ "AIzaSyFAKE"
      refute json =~ "403"
    end

    test "a closed session stops the socket normally" do
      assert {:stop, :normal, _state} =
               Socket.handle_info({:provider, {:closed, :normal}}, state())
    end

    test "a crashed session process stops the socket instead of taking it down silently" do
      pid = self()

      assert {:stop, :normal, _state} =
               Socket.handle_info({:EXIT, pid, :killed}, %{
                 session: pid,
                 provider: LiveCeci.Provider.Gemini
               })
    end

    test "unknown messages are ignored" do
      assert {:ok, _state} = Socket.handle_info(:something_else, state())
    end
  end

  describe "upstream" do
    test "text frames are accepted and ignored — the contract reserves them" do
      assert {:ok, _state} = Socket.handle_in({~s({"type":"start"}), [opcode: :text]}, state())
    end

    test "audio goes through the configured provider, whichever it is" do
      defmodule RecordingProvider do
        @behaviour LiveCeci.Provider
        def open(_opts), do: {:ok, self()}
        def send_audio(_session, pcm), do: send(self(), {:sent, pcm}) && :ok
        def close(_session), do: :ok
      end

      state = %{session: self(), provider: RecordingProvider}
      assert {:ok, _state} = Socket.handle_in({@pcm, [opcode: :binary]}, state)
      assert_received {:sent, @pcm}
    end

    test "a provider that fails to send does not take the socket down" do
      defmodule FailingProvider do
        @behaviour LiveCeci.Provider
        def open(_opts), do: {:ok, self()}
        def send_audio(_session, _pcm), do: {:error, {:exit, {:timeout, :whatever}}}
        def close(_session), do: :ok
      end

      state = %{session: self(), provider: FailingProvider}
      assert {:ok, _state} = Socket.handle_in({@pcm, [opcode: :binary]}, state)
      assert Process.alive?(self())
    end
  end
end
