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

  alias LiveCeci.EnvSandbox

  alias LiveCeci.Socket

  @pcm <<1, 0, 2, 0, 3, 0, 255, 127>>

  defp state, do: %{session: nil, provider: LiveCeci.Provider.Gemini, bytes: 0, last_commit: nil}

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
        def defaults, do: %{model: "m", voice: "v", model_env: "M", voice_env: "V"}
      end

      state = %{session: self(), provider: CommitStub, bytes: 0, last_commit: nil}
      frame = Jason.encode!(%{type: "end_of_speech"})

      assert {:ok, after_commit} = Socket.handle_in({frame, [opcode: :text]}, state)
      assert_received :committed
      # The frame is charged and the commit is stamped. Both used to be absent, and the
      # test asserted the state came back UNCHANGED — which is exactly what let the loop
      # below go unnoticed.
      assert after_commit.bytes == byte_size(frame)
      assert is_integer(after_commit.last_commit)
    end

    test "a commit loop is throttled — thirty bytes must not buy unbounded model turns" do
      # `end_of_speech` becomes `input_audio_buffer.commit` + `response.create` upstream,
      # which is the BILLED unit. Metering bytes does not meter it: one session sending
      # this frame in a loop bought fifteen minutes of responses for nothing. A person
      # cannot end a sentence four times a second, so a quarter-second floor costs a real
      # client nothing.
      defmodule CountingStub do
        @behaviour LiveCeci.Provider
        def open(_opts), do: {:error, :unused}
        def send_audio(_s, _pcm), do: :ok
        def close(_s), do: :ok
        def commit_turn(owner), do: send(owner, :committed) && :ok
        def defaults, do: %{model: "m", voice: "v", model_env: "M", voice_env: "V"}
      end

      frame = Jason.encode!(%{type: "end_of_speech"})

      start = %{session: self(), provider: CountingStub, bytes: 0, last_commit: nil}

      final =
        Enum.reduce(1..200, start, fn _i, acc ->
          {:ok, next} = Socket.handle_in({frame, [opcode: :text]}, acc)
          next
        end)

      commits = drain_commits(0)

      assert commits == 1, "200 commits in a tight loop produced #{commits} upstream turns"
      # Every frame still counted against the budget, throttled or not.
      assert final.bytes == 200 * byte_size(frame)
    end

    test "an unknown or malformed text frame is ignored, not a crash" do
      # The browser is untrusted. Anything that is not the one frame we defined must be
      # dropped without taking the call down.
      state = %{session: self(), provider: LiveCeci.Provider.Grok, bytes: 0, last_commit: nil}

      for junk <- [~s({"type":"teleport"}), "not json at all", "", "[]"] do
        # Charged, like every inbound frame, but nothing else about the state moves — no
        # commit, so no `last_commit`.
        assert {:ok, %{last_commit: nil, bytes: charged}} =
                 Socket.handle_in({junk, [opcode: :text]}, state)

        assert charged == byte_size(junk)
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

  describe "the two bounds on a session" do
    # Bandit's WebSocket :timeout is an IDLE timeout — ThousandIsland applies it as
    # {:persistent, timeout} and every frame read resets it — and an open microphone sends
    # ten frames a second, so it never fired. Nothing else closed a forgotten tab, and the
    # tab held an upstream session that is billed while it lives.
    defmodule QuietProvider do
      @behaviour LiveCeci.Provider
      def open(_opts), do: {:ok, self()}
      def send_audio(_session, _pcm), do: :ok
      def commit_turn(_s), do: :ok
      def close(_session), do: :ok
      def defaults, do: %{model: "m", voice: "v", model_env: "M", voice_env: "V"}
    end

    test "the wall clock closes the session and says why" do
      # The message goes out BEFORE the close, because the browser's onclose reads the
      # last error it was given — without the frame it would tell the user the line
      # dropped, which is not what happened.
      state = %{session: self(), provider: QuietProvider, bytes: 0, last_commit: nil}

      assert {:stop, :normal, 1000, [{:text, frame}], ^state} =
               Socket.handle_info(:session_expired, state)

      assert %{"type" => "error", "message" => message} = Jason.decode!(frame)
      assert message =~ "tempo"
    end

    test "the byte budget closes the session once the microphone has spent it" do
      EnvSandbox.put_env(:max_session_bytes, 8)

      state = %{session: self(), provider: QuietProvider, bytes: 0, last_commit: nil}

      assert {:ok, %{bytes: 4}} = Socket.handle_in({<<1, 2, 3, 4>>, [opcode: :binary]}, state)
    end

    test "spending past the budget ends it with a message, not a silent drop" do
      EnvSandbox.put_env(:max_session_bytes, 8)

      state = %{session: self(), provider: QuietProvider, bytes: 6, last_commit: nil}

      assert {:stop, :normal, 1000, [{:text, frame}], %{bytes: 10}} =
               Socket.handle_in({<<1, 2, 3, 4>>, [opcode: :binary]}, state)

      assert %{"message" => message} = Jason.decode!(frame)
      assert message =~ "limite"
    end

    test "a frame the provider refused is not charged for" do
      # Charging for it would let a stalled upstream close the session early, which is the
      # opposite of what either bound is for.
      EnvSandbox.put_env(:max_session_bytes, 8)

      defmodule RefusingProvider do
        @behaviour LiveCeci.Provider
        def open(_opts), do: {:ok, self()}
        def send_audio(_session, _pcm), do: {:error, :behind}
        def commit_turn(_s), do: :ok
        def close(_session), do: :ok
        def defaults, do: %{model: "m", voice: "v", model_env: "M", voice_env: "V"}
      end

      state = %{session: self(), provider: RefusingProvider, bytes: 7, last_commit: nil}

      assert {:ok, %{bytes: 7}} = Socket.handle_in({<<1, 2, 3, 4>>, [opcode: :binary]}, state)
    end
  end

  describe "frames the contract does not name" do
    test "a control frame is ignored rather than crashing the connection" do
      assert {:ok, _state} = Socket.handle_in({<<>>, [opcode: :ping]}, state())
    end

    test "terminate on a socket that never opened a session closes nothing" do
      # Every state map this module builds carries :session and :provider — refuse/0 and
      # both branches of open_session/0 — so there is exactly one shape terminate/2 ever
      # sees. It used to have a catch-all second clause underneath, which an audit
      # correctly called unreachable; this is the case that clause looked like it was for,
      # and the first clause already handles it.
      assert :ok =
               Socket.terminate(:normal, %{
                 session: nil,
                 provider: nil,
                 bytes: 0,
                 last_commit: nil
               })
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
        def commit_turn(_s), do: :ok
        def close(_session), do: :ok
        def defaults, do: %{model: "m", voice: "v", model_env: "M", voice_env: "V"}
      end

      state = %{session: self(), provider: RecordingProvider, bytes: 0, last_commit: nil}
      assert {:ok, _state} = Socket.handle_in({@pcm, [opcode: :binary]}, state)
      assert_received {:sent, @pcm}
    end

    test "a provider that fails to send does not take the socket down" do
      defmodule FailingProvider do
        @behaviour LiveCeci.Provider
        def open(_opts), do: {:ok, self()}
        def send_audio(_session, _pcm), do: {:error, {:exit, {:timeout, :whatever}}}
        def commit_turn(_s), do: :ok
        def close(_session), do: :ok
        def defaults, do: %{model: "m", voice: "v", model_env: "M", voice_env: "V"}
      end

      state = %{session: self(), provider: FailingProvider, bytes: 0, last_commit: nil}
      assert {:ok, _state} = Socket.handle_in({@pcm, [opcode: :binary]}, state)
      assert Process.alive?(self())
    end
  end

  defp drain_commits(seen) do
    receive do
      :committed -> drain_commits(seen + 1)
    after
      0 -> seen
    end
  end
end
