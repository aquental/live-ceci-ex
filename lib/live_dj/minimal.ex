defmodule LiveDJ.Minimal do
  @moduledoc """
  live-dj, stripped to the primitive — a live voice agent in ~30 lines.

  The whole thing, nothing else: open a session, send the mic up, get voice back,
  play it. No persona, no tools, no transcripts. Everything that makes Mira *Mira*
  lives in `LiveDJ.Socket`; this module is just the loop underneath her.

  Run it instead of the full DJ:

      SOCKET_HANDLER=minimal mix run --no-halt

  Compare it with `LiveDJ.Socket` — the difference between the two files is the
  entire app.
  """

  @behaviour WebSock

  alias Gemini.Live.{Audio, Session}
  alias Gemini.Types.Live.{ServerContent, ServerMessage}

  @impl WebSock
  def init(_opts) do
    owner = self()

    # 1. OPEN
    {:ok, session} =
      Session.start_link(
        model: LiveDJ.config().model,
        generation_config: %{
          response_modalities: ["AUDIO"],
          speech_config: %{
            voice_config: %{prebuilt_voice_config: %{voice_name: LiveDJ.config().voice}}
          }
        },
        on_message: &send(owner, {:gemini, &1})
      )

    :ok = Session.connect(session)
    {:ok, %{session: session}}
  end

  # 2. SEND — browser mic (16 kHz PCM from the AudioWorklet) -> Gemini
  @impl WebSock
  def handle_in({pcm, [opcode: :binary]}, %{session: session} = state) do
    Session.send_realtime_input(session, audio: Audio.create_input_blob(pcm))
    {:ok, state}
  end

  def handle_in(_frame, state), do: {:ok, state}

  # 3. RECEIVE + 4. PLAY — Gemini -> browser (24 kHz voice)
  #
  # No outer loop needed. In Python this is where the agent goes silent after one
  # sentence, because `session.receive()` is a per-turn generator. Here the session
  # is a GenServer that keeps pushing messages for as long as it lives.
  @impl WebSock
  def handle_info(
        {:gemini, %ServerMessage{server_content: %ServerContent{model_turn: %{parts: parts}}}},
        state
      )
      when is_list(parts) do
    {:push,
     for(%{inline_data: %{"data" => b64}} <- parts, do: {:binary, Audio.decode_output(b64)}),
     state}
  end

  def handle_info(_msg, state), do: {:ok, state}
end
