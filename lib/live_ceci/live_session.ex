defmodule LiveCeci.LiveSession do
  @moduledoc """
  A failure-tolerant wrapper over the one `Gemini.Live.Session` call that sits on the
  audio hot path.

  `Session.send_realtime_input/2` is a `GenServer.call` with the default 5 s timeout and
  no way to override it. Two consequences, both bad for a socket process:

    * a call timeout raises an exit IN THE CALLER. `Process.flag(:trap_exit, true)`
      converts exit *signals* from linked processes; it does nothing for an exit raised
      in your own stack. So one stalled upstream takes the browser connection down with
      it — and every listener at once, if the stall is Gemini-side.
    * five seconds is a long time to hold a process that also has to push voice
      downstream. Every queued frame waits behind it.

  So: call with our own timeout, and turn the exit into a value. A dropped mic frame is
  survivable — the stream keeps going. A dropped listener is not.
  """

  alias Gemini.Live.Audio

  # Well under gemini_ex's 5 s default: if a send has not landed within a second the
  # stream is already behind, and dropping the frame beats blocking the socket.
  @send_timeout 1_000

  @doc """
  Sends one chunk of 16 kHz mic PCM upstream. Never raises and never exits.
  """
  @spec send_audio(pid(), binary(), timeout()) :: :ok | {:error, term()}
  def send_audio(session, pcm, timeout \\ @send_timeout) do
    # This is gemini_ex's internal call message rather than its public API, which
    # hardcodes the 5 s timeout. It is why mix.exs pins gemini_ex to the minor.
    GenServer.call(
      session,
      {:send_realtime_input, [audio: Audio.create_input_blob(pcm)]},
      timeout
    )
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end
