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

  # Long enough for a healthy close, short enough that a wedged upstream cannot hold the
  # socket process while the browser waits for the connection to actually end.
  @close_timeout 1_000

  require Logger

  alias Gemini.Live.{Audio, Session}
  alias Gemini.Types.Live.{ServerContent, ServerMessage, ToolCall}

  @impl LiveCeci.Provider
  def defaults do
    %{
      model: "gemini-3.1-flash-live-preview",
      voice: "Aoede",
      model_env: "GOOGLE_LIVE_MODEL",
      voice_env: "GOOGLE_LIVE_VOICE"
    }
  end

  @impl LiveCeci.Provider
  def open(opts) do
    case Session.start_link(session_opts(opts)) do
      {:ok, session} ->
        connect_or_close(session)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The `with` that used to be here dropped `session` when connect/1 failed. Reproduced
  # with an invalid key: open/1 returned {:error, {:setup_failed, ...}} and left one live
  # Gemini.Live.Session process behind, holding an upstream session that is billed.
  #
  # Worse than the same bug was in Grok, where it was fixed first: the LiveCeci.Sessions
  # slot is keyed to the SOCKET pid, so a session leaked this way is invisible to the cap
  # that exists to bound exactly this.
  defp connect_or_close(session) do
    case Session.connect(session) do
      :ok ->
        # The socket must not block on the network, so the blocking call moves to a
        # process of its own. See LiveCeci.Provider.Gemini.Carrier.
        case LiveCeci.Provider.Gemini.Carrier.start_link(session) do
          {:ok, carrier} ->
            {:ok, %{session: session, carrier: carrier}}

          {:error, reason} ->
            close_session(session)
            {:error, reason}
        end

      {:error, reason} ->
        close_session(session)
        {:error, reason}
    end
  end

  # Close AND stop. Session.close/1 shuts the upstream WebSocket — which is what stops
  # the billing, verified in the dependency: do_close/1 calls websocket_module.close/1
  # and nils the socket — but it returns {:reply, :ok, state} and leaves the GenServer
  # running. That process is linked to the socket, and the socket exits :normal, which a
  # process that does not trap exits ignores. Exactly the leak Grok's close/1 documents,
  # for the third time in this codebase and through a third door.
  defp close_session(session) do
    if is_pid(session) and Process.alive?(session) do
      Session.close(session)
      GenServer.stop(session, :normal, @close_timeout)
    end

    :ok
  catch
    :exit, _reason -> :ok
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
  def send_audio(%{carrier: carrier}, pcm),
    do: LiveCeci.Provider.Gemini.Carrier.send_audio(carrier, pcm)

  @impl LiveCeci.Provider
  def commit_turn(_session) do
    # Deliberately nothing. Gemini can do manual turns — realtime_input takes
    # `activity_end` once `automatic_activity_detection` is disabled — but there is no
    # reason to reach for it here: measured over 20 interleaved trials, Gemini answers in
    # 1220 ms with its own VAD, which is already faster than xAI manages at 985 ms with
    # the turn closed by hand. Turning that off would trade a measured win for an
    # unmeasured one and take on the false-turn risk to do it.
    :ok
  end

  @impl LiveCeci.Provider
  def close(session) do
    # Session.close/1 is a GenServer.call with the default 5 s timeout, and this runs
    # inside LiveCeci.Socket.terminate/2. An exit raised there is raised in OUR stack —
    # trap_exit does nothing for that — so a wedged session could take down the very
    # callback that exists to clean it up, and hold the connection process for five
    # seconds on the way. Same guard, same reason, as LiveCeci.Provider.Gemini.Carrier.
    %{session: session} = session

    if is_pid(session) and Process.alive?(session) do
      Task.await(Task.async(fn -> Session.close(session) end), @close_timeout)
    end

    :ok
  catch
    :exit, _reason -> :ok
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
        if command, do: send(owner, {:provider, {:action, command}})
        %{id: id, name: name, response: result}
      end)

    {:tool_response, responses}
  end

  # Same again: a ToolCall whose shape changed would drop every tool the model asks for,
  # and she would keep talking as if nothing had happened.
  def handle_tool_call(other, _owner) do
    Logger.warning("gemini: unrecognised tool call #{LiveCeci.Redact.inspect(other)}")
    :ok
  end

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

  # A ServerMessage with no server_content is routine — setup acks, resumption updates.
  # Silence is correct here.
  def translate(%ServerMessage{}, _owner), do: :ok

  # Anything that is not a ServerMessage at all is NOT routine. mix.exs pins gemini_ex to
  # the minor and the comment there says drift "surfaces as a runtime error, not a compile
  # one" — which was not true of this clause. It matched everything and returned :ok, so a
  # changed struct shape would have taken her voice away with no crash, no log, and a
  # green test suite. The pin does not protect a catch-all; a log does.
  def translate(other, _owner) do
    Logger.warning("gemini: unrecognised server message #{LiveCeci.Redact.inspect(other)}")
    :ok
  end

  @doc false
  def translate_transcript({role, %{"text" => text}}, owner)
      when is_binary(text) and text != "" do
    send(owner, {:provider, {:transcript, transcript_role(role), text}})
    :ok
  end

  # An empty or missing text is routine — the API sends those between fragments.
  def translate_transcript({_role, %{"text" => _}}, _owner), do: :ok

  # A different shape is drift, and would silently delete every transcript. Same reasoning
  # as translate/2 above.
  def translate_transcript(other, _owner) do
    Logger.warning("gemini: unrecognised transcript #{LiveCeci.Redact.inspect(other)}")
    :ok
  end

  defp parts(%ServerContent{model_turn: %{parts: parts}}) when is_list(parts), do: parts
  defp parts(_sc), do: []

  defp transcript_role(:input), do: :user
  defp transcript_role(:output), do: :ceci

  # Leaving the key out entirely is not the same as sending nil: gemini_ex would
  # serialise "languageCode": null, and the API rejects that.
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
