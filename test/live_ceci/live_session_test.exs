defmodule LiveCeci.LiveSessionTest do
  use ExUnit.Case, async: true

  import LiveCeci.Eventually

  alias LiveCeci.LiveSession

  # A stand-in for Gemini.Live.Session: answers the same call message, or never answers.
  defmodule StubSession do
    use GenServer

    def start_link(mode), do: GenServer.start_link(__MODULE__, mode)
    @impl true
    def init(mode), do: {:ok, mode}

    @impl true
    def handle_call({:send_realtime_input, opts}, _from, {:echo, owner} = state) do
      send(owner, {:sent, opts})
      {:reply, :ok, state}
    end

    def handle_call({:send_realtime_input, _opts}, _from, :never_replies = state) do
      Process.sleep(:infinity)
      {:reply, :ok, state}
    end
  end

  describe "send_audio/2" do
    test "the mic chunk reaches the session as a realtime input blob" do
      {:ok, session} = StubSession.start_link({:echo, self()})
      {:ok, carrier} = LiveSession.start_link(session)

      assert :ok = LiveSession.send_audio(carrier, <<1, 2, 3, 4>>)

      assert_receive {:sent, [audio: blob]}, 1_000
      assert %{data: <<1, 2, 3, 4>>, mime_type: "audio/pcm;rate=16000"} = blob
    end

    test "a stalled session never blocks the caller" do
      # THE reason this module became a process. It used to make the blocking call on the
      # socket process — measured at 1001 ms for a single frame against a wedged session,
      # on the process that also has to push her voice to the browser. Ten frames a
      # second went through that.
      {:ok, session} = StubSession.start_link(:never_replies)
      {:ok, carrier} = LiveSession.start_link(session)

      {elapsed, :ok} = :timer.tc(fn -> LiveSession.send_audio(carrier, <<0, 0>>) end)

      assert elapsed < 50_000,
             "send_audio took #{elapsed}µs — the socket process must never wait on the network"

      assert Process.alive?(self())
    end

    test "a dead session is not an error the caller has to handle" do
      {:ok, session} = StubSession.start_link({:echo, self()})
      {:ok, carrier} = LiveSession.start_link(session)
      Process.unlink(session)
      ref = Process.monitor(session)
      Process.exit(session, :kill)
      assert_receive {:DOWN, ^ref, :process, ^session, :killed}

      assert :ok = LiveSession.send_audio(carrier, <<0, 0>>)
      assert Process.alive?(self())
    end

    test "the queue is bounded, so a slow upstream cannot grow it without end" do
      # The failure the first version of the Grok fix shipped: casting instead of calling
      # does not remove the queue, it moves it. Measured there before this bound existed:
      # 5_000 frames at a process that was not draining produced a 5_000-message, 1 MB
      # mailbox and :ok every single time.
      {:ok, session} = StubSession.start_link(:never_replies)
      {:ok, carrier} = LiveSession.start_link(session)

      for _ <- 1..2_000, do: LiveSession.send_audio(carrier, <<0, 0>>)

      assert eventually(fn ->
               {:message_queue_len, queued} = Process.info(carrier, :message_queue_len)
               queued <= 40
             end),
             "the carrier mailbox grew past the bound"
    end
  end

  describe "the assumption this module is built on" do
    # LiveSession does not call gemini_ex's public API. It sends the INTERNAL GenServer
    # message that Session.send_realtime_input/2 wraps, because the public function
    # hardcodes a 5 s timeout and this call sits on the audio path.
    #
    # mix.exs pins gemini_ex to the minor and says drift "surfaces as a runtime error".
    # That is not true here either: a patch release is exactly where an internal message
    # is allowed to change shape, and nothing in this repo would notice until a live call
    # went silent. The pin cannot check an assumption. This can.
    @session_source Path.join([
                      __DIR__,
                      "..",
                      "..",
                      "deps",
                      "gemini_ex",
                      "lib",
                      "gemini",
                      "live",
                      "session.ex"
                    ])

    test "gemini_ex still handles the internal message LiveSession sends" do
      source = File.read!(@session_source)

      assert source =~ ~r/def handle_call\(\{:send_realtime_input, opts\}/,
             "gemini_ex no longer handles {:send_realtime_input, opts} as a call. " <>
               "LiveCeci.LiveSession sends exactly that message and would now time out " <>
               "on every microphone frame. Check deps/gemini_ex CHANGELOG before bumping."
    end

    test "the public wrapper still hardcodes the timeout that made this necessary" do
      # If gemini_ex ever accepts a timeout, this module should stop reaching inside.
      source = File.read!(@session_source)

      assert source =~ ~r/GenServer\.call\(session, \{:send_realtime_input, opts\}\)/,
             "gemini_ex's send_realtime_input/2 changed. If it now takes a timeout, " <>
               "LiveCeci.LiveSession can go back to the public API and this file can shrink."
    end
  end
end
