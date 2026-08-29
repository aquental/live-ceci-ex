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
end
