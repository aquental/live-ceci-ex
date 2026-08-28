defmodule LiveDJ.Socket do
  @moduledoc """
  live-dj — the Gemini Live bridge (EP1, ported to Elixir).

  One browser WebSocket = one process = one `Gemini.Live.Session`. Where the Python
  version runs two asyncio tasks (mic up, audio down), the BEAM needs neither: the
  socket process *is* the upstream (`handle_in`) and the downstream (`handle_info`),
  and the Live session is a linked GenServer that pushes messages into our mailbox.

  ## The gotcha that isn't

  The Python original exists to teach one bug: `session.receive()` is a PER-TURN async
  generator, so iterating it once makes the agent answer a single sentence and go silent
  forever. It needs an outer `while True`.

  There is no equivalent here, and no way to write it wrong: `Gemini.Live.Session` is a
  GenServer that *pushes* every server message through callbacks. There is no loop to
  forget to restart. The lesson survives only as this note.

  Its sibling gotcha does survive: mic audio goes to `send_realtime_input/2`, NOT
  `send_client_content/3` — live audio is a stream, not a discrete turn, and the wrong
  one leaves the model never hearing you. See `handle_in/2`.

  ## The wire contract (identical to the Python server, so the frontend is unchanged)

  Browser -> server: binary frames of 16 kHz mono PCM s16le.
  Server -> browser: binary frames of 24 kHz PCM (voice), plus JSON text frames:
    `{"type":"transcript","role":"user"|"mira","text":...}`
    `{"type":"play","action":"playlist"|"track"|"skip"|"pause","value":...}`
    `{"type":"interrupted"}`
    `{"type":"error","message":...}`
  """

  @behaviour WebSock

  require Logger

  alias Gemini.Live.{Audio, Session}
  alias Gemini.Types.Live.{ServerContent, ServerMessage, ToolCall}

  @impl WebSock
  def init(_opts) do
    # Trap exits so a Live-session crash becomes a message we can report to the
    # browser, instead of silently taking this process down with it.
    Process.flag(:trap_exit, true)

    owner = self()
    config = LiveDJ.config()

    session_opts = [
      model: config.model,
      system_instruction: LiveDJ.Persona.system_instruction(),
      tools: LiveDJ.Tools.live_tools(),
      generation_config: %{
        response_modalities: ["AUDIO"],
        speech_config: %{voice_config: %{prebuilt_voice_config: %{voice_name: config.voice}}}
      },
      input_audio_transcription: %{},
      output_audio_transcription: %{},
      # Gemini closes a turn on its own once it hears enough silence, and until it does,
      # nothing comes back. Left unset it uses Google's default, which is undocumented
      # here and long enough to feel like a stall on short utterances. Measured for
      # contrast: with a text turn — where the turn closes on send and no detection runs —
      # first audio comes back in ~900 ms.
      realtime_input_config: %{
        automatic_activity_detection: %{
          silence_duration_ms: 500,
          end_of_speech_sensitivity: :high
        }
      },
      on_message: &send(owner, {:gemini, &1}),
      on_transcription: &send(owner, {:transcription, &1}),
      on_error: &send(owner, {:gemini_error, &1}),
      on_close: &send(owner, {:gemini_closed, &1}),
      # Runs inside the Session process. It must return INSTANTLY — the model's voice
      # is paused until it does. So: decide the command, hand it to the socket process,
      # return `{:ok, ...}` in the same breath. Never await playback here.
      on_tool_call: fn tool_call -> handle_tool_call(tool_call, owner) end
    ]

    Logger.info(
      "ws connected; opening Live session (model=#{config.model}, voice=#{config.voice})"
    )

    with {:ok, session} <- Session.start_link(session_opts),
         :ok <- Session.connect(session) do
      Logger.info("Live session open")
      {:ok, %{session: session}}
    else
      {:error, reason} ->
        Logger.error("failed to open Live session: #{inspect(reason)}")
        # Close, don't linger. A socket left alive with session: nil sends every later
        # binary frame into the no-op clause below, and the browser's continuous mic
        # traffic keeps resetting the idle timeout — so it would never close on its own.
        {:stop, :normal, 1011, error_frame(reason), %{session: nil}}
    end
  end

  # ---------------------------------------------------------------- upstream

  @impl WebSock
  def handle_in({pcm, [opcode: :binary]}, %{session: session} = state) when session != nil do
    # THE GOTCHA THAT SURVIVES: live mic audio is a STREAM, so it goes to
    # send_realtime_input. send_client_content is only for seeding history before
    # the conversation — use it for the mic and the turn never fires. Dead air.
    # ...through a wrapper, because the underlying call is a GenServer.call whose
    # timeout would exit *this* process. See LiveDJ.LiveSession.
    case LiveDJ.LiveSession.send_audio(session, pcm) do
      :ok ->
        {:ok, state}

      {:error, reason} ->
        Logger.warning("send_realtime_input failed: #{inspect(reason)}")
        {:ok, state}
    end
  end

  # The frontend never sends text frames today; the contract reserves them for
  # `{"type":"start"|"stop"}`, so accept and ignore rather than crash.
  def handle_in({_data, [opcode: :text]}, state), do: {:ok, state}
  def handle_in(_frame, state), do: {:ok, state}

  # -------------------------------------------------------------- downstream

  @impl WebSock
  # Voice: 24 kHz PCM arrives base64-encoded inside the model turn's parts.
  def handle_info({:gemini, %ServerMessage{server_content: %ServerContent{} = sc}}, state) do
    frames = voice_frames(sc) ++ interrupted_frame(sc)
    if frames == [], do: {:ok, state}, else: {:push, frames, state}
  end

  def handle_info({:gemini, %ServerMessage{}}, state), do: {:ok, state}

  def handle_info({:transcription, {role, %{"text" => text}}}, state)
      when is_binary(text) and text != "" do
    {:push, json(%{type: "transcript", role: transcript_role(role), text: text}), state}
  end

  def handle_info({:transcription, _other}, state), do: {:ok, state}

  # A tool call decided a music command; forward it to the browser's player.
  def handle_info({:play, command}, state) do
    {:push, json(Map.put(command, :type, "play")), state}
  end

  def handle_info({:gemini_error, reason}, state) do
    Logger.error("Live session error: #{inspect(reason)}")
    {:push, error_frame(reason), state}
  end

  def handle_info({:gemini_closed, reason}, state) do
    Logger.info("Live session closed: #{inspect(reason)}")
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, pid, reason}, %{session: pid} = state) do
    Logger.error("Live session process exited: #{inspect(reason)}")
    {:stop, :normal, %{state | session: nil}}
  end

  def handle_info(msg, state) do
    Logger.debug("socket: unhandled message #{inspect(msg)}")
    {:ok, state}
  end

  @impl WebSock
  def terminate(reason, %{session: session}) do
    Logger.info("ws closed (#{inspect(reason)})")
    if is_pid(session) and Process.alive?(session), do: Session.close(session)
    :ok
  end

  def terminate(_reason, _state), do: :ok

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
        {command, result} = LiveDJ.Tools.dispatch(name, call.args || %{})
        if command, do: send(owner, {:play, command})
        %{id: id, name: name, response: result}
      end)

    {:tool_response, responses}
  end

  def handle_tool_call(_tool_call, _owner), do: :ok

  # ----------------------------------------------------------------- private

  defp voice_frames(%ServerContent{model_turn: %{parts: parts}}) when is_list(parts) do
    for %{inline_data: %{"data" => b64}} <- parts, do: {:binary, Audio.decode_output(b64)}
  end

  defp voice_frames(_sc), do: []

  defp interrupted_frame(%ServerContent{interrupted: true}), do: json(%{type: "interrupted"})
  defp interrupted_frame(_sc), do: []

  defp transcript_role(:input), do: "user"
  defp transcript_role(:output), do: "mira"

  # The browser is untrusted, and an upstream reason can carry quota/billing state or a
  # URL with the API key in it. The detail stays in the log — both call sites log it —
  # and the client gets a fixed string.
  defp error_frame(_reason) do
    json(%{type: "error", message: "the line dropped — try again"})
  end

  # WebSock takes a list of frames; keeping every builder list-shaped makes them
  # composable with `++`.
  defp json(payload), do: [{:text, Jason.encode!(payload)}]
end
