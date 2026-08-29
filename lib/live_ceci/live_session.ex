defmodule LiveCeci.LiveSession do
  @moduledoc """
  The process that carries microphone audio to Gemini, so the socket does not.

  ## What this used to be, and why that was wrong twice

  It was a module of functions, and `send_audio/3` was a `GenServer.call` made **on the
  socket process** — the same process that pushes her voice back to the browser. A slow
  upstream ACK therefore stalled outbound voice: measured, one frame against a wedged
  session blocked the caller for 1001 ms, and mic frames arrive ten times a second.

  The obvious fix was the one applied to Grok first: stop blocking, cast instead. That
  traded one failure for another. `WebSockex.cast/2` never blocks, Bandit reads at
  loopback speed and the upstream drains at WAN speed, so the queue simply moves — 5_000
  frames cast at a process that was not draining produced a 5_000-message, 1 MB mailbox
  and `:ok` every single time, with no signal that anything was wrong.

  Blocking and not-blocking were never the only two options. The third is to put the
  waiting somewhere it does no harm and to **bound the queue**, which is what this
  process is. The socket casts and returns immediately; this process does the blocking
  call; and when it falls behind, frames are dropped with a log rather than accumulated
  in silence.

  Dropping is correct for live audio specifically. A mic frame that arrives late is
  worth nothing — the moment it described has passed — and the stream recovers by
  itself. It is the same trade the browser makes with `bufferedAmount` and the socket
  makes when shedding voice downstream.
  """

  use GenServer

  require Logger

  alias Gemini.Live.Audio

  # Well under gemini_ex's 5 s default: if a send has not landed within a second the
  # stream is already behind, and dropping the frame beats holding this process.
  @send_timeout 1_000

  # Roughly two seconds of microphone at ten frames a second. Past this the upstream is
  # not keeping up and older frames are worthless anyway.
  @max_queued 20

  @doc """
  Starts the carrier for one Gemini session. Linked to the caller, so it dies with the
  socket that owns it.
  """
  @spec start_link(pid()) :: {:ok, pid()} | {:error, term()}
  def start_link(session), do: GenServer.start_link(__MODULE__, session)

  @doc """
  Hands one chunk of 16 kHz mic PCM to the carrier. Never blocks, never raises, never
  exits — the socket process must not wait on the network.
  """
  @spec send_audio(pid(), binary()) :: :ok
  def send_audio(carrier, pcm) do
    GenServer.cast(carrier, {:audio, pcm})
  catch
    :exit, _reason -> :ok
  end

  # ---------------------------------------------------------------- server

  @impl GenServer
  def init(session), do: {:ok, %{session: session, dropped: 0}}

  @impl GenServer
  def handle_cast({:audio, pcm}, state) do
    # The bound. Checked here rather than in send_audio/2 because the caller cannot see
    # this mailbox without a round trip, and a round trip is the thing being avoided.
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, queued} when queued > @max_queued ->
        if rem(state.dropped, 50) == 0 do
          Logger.warning("gemini carrier behind: #{queued} frames queued, dropping")
        end

        {:noreply, %{state | dropped: state.dropped + 1}}

      _ ->
        deliver(state.session, pcm)
        {:noreply, state}
    end
  end

  defp deliver(session, pcm) do
    # gemini_ex's internal call message rather than its public API, which hardcodes a 5 s
    # timeout. It is why mix.exs pins gemini_ex to the minor, and why
    # live_session_test.exs reads the dependency to check the clause still exists.
    #
    # A timeout raises an exit in THIS process now, not in the socket's, which is the
    # whole point — but it is still caught, because a dropped frame must not restart the
    # carrier and lose the ones behind it.
    GenServer.call(
      session,
      {:send_realtime_input, [audio: Audio.create_input_blob(pcm)]},
      @send_timeout
    )
  catch
    :exit, reason ->
      Logger.warning("gemini send failed: #{LiveCeci.Redact.inspect(reason)}")
      :ok
  end
end
