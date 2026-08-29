defmodule LiveCeci.LiveSessionTest do
  use ExUnit.Case, async: true

  alias LiveCeci.LiveSession

  # A stand-in for Gemini.Live.Session: answers the same call message, or never answers.
  defmodule StubSession do
    use GenServer

    def start_link(mode), do: GenServer.start_link(__MODULE__, mode)
    @impl true
    def init(mode), do: {:ok, mode}

    @impl true
    def handle_call({:send_realtime_input, opts}, _from, :ok = state) do
      {:reply, {:ok, opts}, state}
    end

    def handle_call({:send_realtime_input, _opts}, _from, :never_replies = state) do
      Process.sleep(:infinity)
      {:reply, :ok, state}
    end
  end

  describe "send_audio/3" do
    test "sends the mic chunk as a realtime input blob" do
      {:ok, session} = StubSession.start_link(:ok)

      assert {:ok, [audio: blob]} = LiveSession.send_audio(session, <<1, 2, 3, 4>>)
      assert %{data: <<1, 2, 3, 4>>, mime_type: "audio/pcm;rate=16000"} = blob
    end

    test "a stalled session returns an error instead of exiting the caller" do
      {:ok, session} = StubSession.start_link(:never_replies)

      # The whole point: trap_exit does NOT catch an exit raised in this process, so
      # without the catch this line would kill the socket — and the browser call with it.
      assert {:error, {:exit, {:timeout, _}}} = LiveSession.send_audio(session, <<0, 0>>, 20)
      assert Process.alive?(self())
    end

    test "a dead session returns an error instead of exiting the caller" do
      {:ok, session} = StubSession.start_link(:ok)
      # unlink first, or killing the stub takes this test process down with it
      Process.unlink(session)
      ref = Process.monitor(session)
      Process.exit(session, :kill)
      assert_receive {:DOWN, ^ref, :process, ^session, :killed}

      assert {:error, {:exit, {:noproc, _}}} = LiveSession.send_audio(session, <<0, 0>>, 20)
      assert Process.alive?(self())
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
