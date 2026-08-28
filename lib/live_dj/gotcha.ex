defmodule LiveDJ.Gotcha do
  @moduledoc """
  EP1's "where the AI got it wrong" — kept compilable so the failure is real on camera.

  Prompt a coding agent with "send the user's mic audio to the Gemini Live session" and
  it very often reaches for `send_client_content` — it's the documented way to send
  *content*. But live audio is a STREAM, not a discrete turn. `send_client_content` is
  only for seeding history before the conversation; used for the mic, the live turn
  never fires and you get dead air.

  The fix is one line: `send_realtime_input`. (That's what `LiveDJ.Socket` uses.)

  ## The other gotcha, and why it's missing

  The Python original has a second, bigger one: `session.receive()` is a PER-TURN async
  generator, so a naive `async for response in session.receive()` answers exactly one
  sentence and then goes silent forever. It needs an outer `while True`.

  That bug cannot be written in Elixir. `Gemini.Live.Session` is a GenServer that pushes
  every server message to your process through callbacks — there is no generator to
  exhaust and no loop to forget to restart. The actor model deletes the whole class of
  bug, which is good engineering and a worse demo.
  """

  alias Gemini.Live.{Audio, Session}

  @doc """
  THE WRONG WAY — what the AI tends to write.

  The live turn doesn't fire as expected. Dead air.
  """
  @spec send_mic_audio_wrong(pid(), binary()) :: :ok | {:error, term()}
  def send_mic_audio_wrong(session, pcm_16k) do
    Session.send_client_content(session, [
      %{
        role: "user",
        parts: [%{inline_data: %{data: pcm_16k, mime_type: "audio/pcm;rate=16000"}}]
      }
    ])
  end

  @doc """
  THE RIGHT WAY — live input is a continuous realtime stream.
  """
  @spec send_mic_audio_right(pid(), binary()) :: :ok | {:error, term()}
  def send_mic_audio_right(session, pcm_16k) do
    Session.send_realtime_input(session, audio: Audio.create_input_blob(pcm_16k))
  end
end
