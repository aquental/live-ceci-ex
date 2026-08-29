defmodule LiveCeci.Provider.Grok do
  @moduledoc """
  `LiveCeci.Provider` over xAI's Voice Agent API.

  The protocol is OpenAI Realtime's, so this is a JSON event stream over a plain
  WebSocket rather than a typed client library — there is no Elixir package for it,
  which is why the transport is hand-rolled on `websockex`.

  Two things differ from Gemini in ways that show up in the code below:

    * Audio crosses as raw WebSocket binary frames in both directions. xAI's JSON
      transport would carry it base64-encoded instead — 33% more on the wire and an
      encode per 100 ms mic frame. The spike verified binary works both ways, so the
      JSON audio path survives here only as a fallback clause.

    * Answering a tool call takes two messages — the result, then an explicit
      request for a new response. Gemini takes one.

  Audio formats are negotiated to exactly what the browser already speaks, 16 kHz
  up and 24 kHz down, so nothing in `priv/frontend` changes when this provider is
  selected.
  """

  @behaviour LiveCeci.Provider
  use WebSockex

  require Logger

  @endpoint "wss://api.x.ai/v1/realtime"

  # Same budget as the Gemini path: long enough for a healthy round trip, short
  # enough that a wedged upstream cannot hold the socket process for seconds.
  @send_timeout 1_000

  # ------------------------------------------------------------------ provider

  @impl LiveCeci.Provider
  def open(opts) do
    owner = Keyword.fetch!(opts, :owner)
    model = Keyword.fetch!(opts, :model)
    key = Keyword.get(opts, :api_key) || System.get_env("GROK_API_KEY")

    cond do
      key in [nil, ""] ->
        {:error, :missing_grok_api_key}

      true ->
        url = "#{@endpoint}?model=#{model}"

        case WebSockex.start_link(url, __MODULE__, %{owner: owner},
               extra_headers: [{"Authorization", "Bearer " <> key}]
             ) do
          {:ok, ws} ->
            case send_json(ws, session_update(opts)) do
              :ok ->
                {:ok, ws}

              {:error, reason} ->
                # Close before returning. By this line the upstream session is already
                # OPEN and billed; the `with` that used to be here dropped `ws` on the
                # floor and left it that way until xAI's own timeout. Nothing downstream
                # cleans it up: Socket.init stores session: nil on an error, so
                # terminate/2 never calls close/1, and the socket's :normal exit is
                # ignored by a WebSockex process that does not trap. Exactly the leak the
                # comment on close/1 describes, arriving through a different door.
                close(ws)
                {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @impl LiveCeci.Provider
  def send_audio(ws, pcm) do
    # Straight out as a binary frame — no envelope, no base64. The session negotiated
    # `transport: "binary"`, so this is what the server expects on the input buffer.
    #
    # A cast, not send_frame/3. The socket process is BOTH directions for one listener:
    # it takes the microphone in handle_in/2 and pushes her voice out in handle_info/2.
    # send_frame/3 is a :gen.call, so a slow upstream ACK held the socket for up to a
    # second per ~100 ms mic frame, and voice frames already decoded and ready for the
    # browser waited behind it. Casting hands the frame to the WebSockex process and
    # returns immediately; that process is where the waiting belongs.
    #
    # What this gives up is per-frame backpressure and a per-frame error. Neither was
    # worth much: send_audio's only caller already logs and drops on error, and a dropped
    # mic frame is survivable by design. A dead session still surfaces through
    # handle_disconnect/2 as {:closed, reason}.
    WebSockex.cast(ws, {:send_audio, pcm})
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @impl LiveCeci.Provider
  def close(ws) do
    # Not Process.exit(ws, :normal): sent to another process that is not trapping
    # exits, a :normal signal is silently ignored, so the session stayed open upstream
    # — billed — until the remote timed out. A cast reaches handle_cast/2, which
    # returns {:close, state} and sends a proper close frame.
    if is_pid(ws) and Process.alive?(ws), do: WebSockex.cast(ws, :close)
    :ok
  end

  # ----------------------------------------------------------------- websockex

  @impl WebSockex
  def handle_frame({:text, raw}, state) do
    case Jason.decode(raw) do
      {:ok, event} ->
        # translate/2 returns anything that has to go back upstream. It cannot send
        # directly: WebSockex.send_frame/3 raises CallingSelfError when the caller is
        # the socket process, which this is. Casting to ourselves routes it through
        # handle_cast/2, which may reply with a frame.
        for payload <- translate(event, state.owner), do: WebSockex.cast(self(), {:send, payload})

      {:error, _} ->
        Logger.debug("grok: undecodable frame")
    end

    {:ok, state}
  end

  # Voice, already decoded by virtue of never having been encoded.
  def handle_frame({:binary, pcm}, state) do
    send(state.owner, {:provider, {:voice, pcm}})
    {:ok, state}
  end

  def handle_frame(_frame, state), do: {:ok, state}

  @impl WebSockex
  def handle_cast(:close, state), do: {:close, state}

  def handle_cast({:send, payload}, state) do
    {:reply, {:text, Jason.encode!(payload)}, state}
  end

  def handle_cast({:send_audio, pcm}, state), do: {:reply, {:binary, pcm}, state}

  @impl WebSockex
  def handle_disconnect(%{reason: reason}, state) do
    send(state.owner, {:provider, {:closed, reason}})
    {:ok, state}
  end

  # ----------------------------------------------------------------- translate

  # Fallback only: with binary transport negotiated the voice arrives as frames, not
  # here. Kept because a server that ignores the transport request would otherwise go
  # silent with no clue why.
  defp translate(%{"type" => "response.output_audio.delta", "delta" => b64}, owner) do
    case Base.decode64(b64) do
      {:ok, pcm} -> send(owner, {:provider, {:voice, pcm}})
      :error -> :ok
    end

    []
  end

  # The user started talking over her. Gemini reports this as `interrupted` on the
  # server content; Grok reports the cause rather than the effect, but the socket
  # wants the same thing either way — tell the browser to drop queued audio.
  defp translate(%{"type" => "input_speech.started"}, owner) do
    send(owner, {:provider, :interrupted})
    []
  end

  # Cumulative, not incremental: each update carries the whole transcript so far,
  # where Gemini sends fragments. The socket replaces rather than appends.
  defp translate(
         %{"type" => "conversation.item.input_audio_transcription.updated", "transcript" => t},
         owner
       )
       when is_binary(t) and t != "" do
    send(owner, {:provider, {:transcript, :user, t}})
    []
  end

  defp translate(%{"type" => "response.output_audio_transcript.done", "transcript" => t}, owner)
       when is_binary(t) and t != "" do
    send(owner, {:provider, {:transcript, :ceci, t}})
    []
  end

  # Dispatched here rather than on the socket process: the model's voice is paused
  # until the result goes back, and bouncing it through another process would only
  # add a hop. dispatch/2 is a pattern match over plain data, so this is safe on the
  # WebSockex process.
  defp translate(
         %{
           "type" => "response.function_call_arguments.done",
           "name" => name,
           "call_id" => id,
           "arguments" => args
         },
         owner
       ) do
    {command, result} = LiveCeci.Tools.dispatch(name, decode_args(args))
    if command, do: send(owner, {:provider, {:action, command}})
    tool_result_payloads(id, result)
  end

  defp translate(%{"type" => "error"} = event, owner) do
    send(owner, {:provider, {:error, Map.get(event, "error", event)}})
    []
  end

  defp translate(_event, _owner), do: []

  # Two messages, not one: the result, then an explicit request for a new response.
  # Without the second the model has the answer but never resumes speaking.
  defp tool_result_payloads(id, result) do
    [
      %{
        type: "conversation.item.create",
        item: %{type: "function_call_output", call_id: id, output: Jason.encode!(result)}
      },
      %{type: "response.create"}
    ]
  end

  @doc false
  # Public only so a test can see it. This map is the entire behaviour contract of a
  # session — audio rates, VAD timings, transport, tools, persona — and a typo in any
  # of it compiles clean and misbehaves at runtime. Takes the same keyword list as
  # open/1 rather than positional arguments, so a new knob does not bump the arity.
  def session_update(opts) do
    voice = Keyword.fetch!(opts, :voice)
    language = Keyword.get(opts, :language)
    silence_ms = Keyword.get(opts, :silence_duration_ms, 400)

    %{
      type: "session.update",
      session: %{
        voice: voice,
        # Gemini takes a Content struct here; Grok takes a bare string.
        instructions: LiveCeci.Persona.instruction(),
        turn_detection: %{
          type: "server_vad",
          silence_duration_ms: silence_ms,
          # If the listener goes quiet this long after she finishes, she speaks first
          # rather than both sides waiting. Long enough not to talk over a pause.
          idle_timeout_ms: 15_000
        },
        audio: %{
          input:
            %{format: %{type: "audio/pcm", rate: 16_000}, transport: "binary"}
            |> maybe_transcription(language),
          output: %{format: %{type: "audio/pcm", rate: 24_000}, transport: "binary"}
        },
        tools: tools()
      }
    }
  end

  # ------------------------------------------------------------------- private

  # LiveCeci.Tools already emits JSON Schema; Grok only wants a `type` alongside it.
  defp tools do
    Enum.map(LiveCeci.Tools.declarations(), fn d ->
      %{type: "function", name: d.name, description: d.description, parameters: d.parameters}
    end)
  end

  defp decode_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end

  defp decode_args(%{} = args), do: args
  defp decode_args(_), do: %{}

  # Omitted rather than sent as nil: the field is optional, and xAI rejects a null.
  defp maybe_transcription(input, nil), do: input

  defp maybe_transcription(input, language),
    do: Map.put(input, :transcription, %{language_hint: language})

  # WebSockex.send_frame/3 is a :gen.call, so an unresponsive socket would exit the
  # CALLER — the socket process carrying the microphone. Same hazard, same guard as
  # LiveCeci.LiveSession on the Gemini side.
  defp send_json(ws, payload) do
    WebSockex.send_frame(ws, {:text, Jason.encode!(payload)}, @send_timeout)
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end
