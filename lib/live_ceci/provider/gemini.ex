defmodule LiveCeci.Provider.Gemini do
  @moduledoc """
  `LiveCeci.Provider` over the Gemini Live API, through `gemini_ex`.

  All the struct matching that used to live in `LiveCeci.Socket` is here, because it is
  the part that is true of Gemini and nothing else: voice arrives base64-encoded
  inside `serverContent.modelTurn.parts`, interruption arrives as a boolean on the
  same struct, and transcripts arrive through a separate callback tagged `:input` or
  `:output`.

  The tool callback is the reason `LiveCeci.Provider` has no `send_tool_result/3`:
  `gemini_ex` wants the responses as this function's RETURN value, synchronously,
  while the model's voice stays paused. See `handle_tool_call/2`.
  """

  @behaviour LiveCeci.Provider

  alias Gemini.Live.{Audio, Session}
  alias Gemini.Types.Live.{ServerContent, ServerMessage, ToolCall}

  @impl LiveCeci.Provider
  def open(opts) do
    with {:ok, session} <- Session.start_link(session_opts(opts)),
         :ok <- Session.connect(session) do
      {:ok, session}
    end
  end

  @doc false
  # Public only so a test can see it. This keyword list is the entire behaviour
  # contract of a session — voice, persona, tools, transcription, VAD timings — and a
  # typo in any of it compiles clean and misbehaves at runtime.
  def session_opts(opts) do
    owner = Keyword.fetch!(opts, :owner)
    model = Keyword.fetch!(opts, :model)
    voice = Keyword.fetch!(opts, :voice)
    language = Keyword.get(opts, :language)
    silence_ms = Keyword.get(opts, :silence_duration_ms, 400)

    [
      model: model,
      system_instruction: LiveCeci.Persona.system_instruction(),
      tools: LiveCeci.Tools.live_tools(),
      generation_config: %{
        response_modalities: ["AUDIO"],
        speech_config:
          %{voice_config: %{prebuilt_voice_config: %{voice_name: voice}}}
          |> maybe_put(:language_code, language)
      },
      input_audio_transcription: %{},
      output_audio_transcription: %{},
      # Gemini closes a turn on its own once it hears enough silence, and until it does,
      # nothing comes back. Left unset it uses Google's default, which is undocumented
      # here and long enough to feel like a stall on short utterances. Measured for
      # contrast: with a text turn — where the turn closes on send and no detection runs —
      # first audio comes back in ~900 ms, so this value is added on top of that.
      realtime_input_config: %{
        automatic_activity_detection: %{
          silence_duration_ms: silence_ms,
          end_of_speech_sensitivity: :high
        }
      },
      on_message: &translate(&1, owner),
      on_transcription: &translate_transcript(&1, owner),
      on_error: &send(owner, {:provider, {:error, &1}}),
      on_close: &send(owner, {:provider, {:closed, &1}}),
      on_tool_call: fn tool_call -> handle_tool_call(tool_call, owner) end
    ]
  end

  @impl LiveCeci.Provider
  def send_audio(session, pcm), do: LiveCeci.LiveSession.send_audio(session, pcm)

  @impl LiveCeci.Provider
  def close(session) do
    if is_pid(session) and Process.alive?(session), do: Session.close(session)
    :ok
  end

  @doc """
  Dispatches a model tool call and returns the responses for `gemini_ex` to send back.

  Runs inside the Live session process, and is SYNCHRONOUS by design: the model's voice
  stays paused until it returns, so it only decides a command, hands it to `owner`, and
  returns. Public so the dispatch path is testable without a live session.
  """
  @spec handle_tool_call(ToolCall.t(), pid()) :: {:tool_response, [map()]} | :ok
  def handle_tool_call(%ToolCall{function_calls: calls}, owner) when is_list(calls) do
    responses =
      Enum.map(calls, fn %{id: id, name: name} = call ->
        {command, result} = LiveCeci.Tools.dispatch(name, call.args || %{})
        if command, do: send(owner, {:provider, {:play, command}})
        %{id: id, name: name, response: result}
      end)

    {:tool_response, responses}
  end

  def handle_tool_call(_tool_call, _owner), do: :ok

  # ------------------------------------------------------------------ private

  @doc false
  # Public-ish through the callback closures above; kept private to the module API.
  def translate(%ServerMessage{server_content: %ServerContent{} = sc}, owner) do
    for %{inline_data: %{"data" => b64}} <- parts(sc) do
      send(owner, {:provider, {:voice, Audio.decode_output(b64)}})
    end

    if sc.interrupted, do: send(owner, {:provider, :interrupted})
    :ok
  end

  def translate(%ServerMessage{}, _owner), do: :ok
  def translate(_other, _owner), do: :ok

  @doc false
  def translate_transcript({role, %{"text" => text}}, owner)
      when is_binary(text) and text != "" do
    send(owner, {:provider, {:transcript, transcript_role(role), text}})
    :ok
  end

  def translate_transcript(_other, _owner), do: :ok

  defp parts(%ServerContent{model_turn: %{parts: parts}}) when is_list(parts), do: parts
  defp parts(_sc), do: []

  defp transcript_role(:input), do: :user
  defp transcript_role(:output), do: :mira

  # Leaving the key out entirely is not the same as sending nil: gemini_ex would
  # serialise "languageCode": null, and the API rejects that.
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
