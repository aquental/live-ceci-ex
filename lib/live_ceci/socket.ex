defmodule LiveCeci.Socket do
  @moduledoc """
  live-ceci — the live-voice bridge.

  One browser WebSocket = one process = one provider session. No reader task and no
  receive loop: the socket process *is* the upstream (`handle_in`) and the downstream
  (`handle_info`), and the provider session is a linked GenServer that pushes server
  messages into our mailbox. There is no iteration to forget to restart, which is the
  shape of bug this design cannot express.

  ## Which backend

  `LiveCeci.Provider.current/0` picks Gemini Live or xAI's Voice Agent from `MODEL`.
  This module never learns which: providers translate their wire format into the
  neutral events documented in `LiveCeci.Provider`, so everything below is the same
  either way — including the frames the browser receives.

  The one real trap is upstream: mic audio goes to `send_realtime_input/2`, NOT
  `send_client_content/3` — live audio is a stream, not a discrete turn, and the wrong
  one leaves the model never hearing you. See `handle_in/2`.

  ## The wire contract

  Browser -> server: binary frames of 16 kHz mono PCM s16le.
  Server -> browser: binary frames of 24 kHz PCM (voice), plus JSON text frames:
    `{"type":"transcript","role":"user"|"ceci","text":...}`
    `{"type":"action","action":"agendar"|"presenca"|"recibo"|"resumo","detail":...}`
    `{"type":"interrupted"}`
    `{"type":"error","message":...}`
  """

  @behaviour WebSock

  require Logger

  alias LiveCeci.Provider

  @impl WebSock
  def init(_opts) do
    # Trap exits so a provider crash becomes a message we can report to the browser,
    # instead of silently taking this process down with it.
    Process.flag(:trap_exit, true)

    config = LiveCeci.config()
    provider = Provider.current()

    Logger.info(
      "ws connected; opening #{inspect(provider)} session " <>
        "(model=#{config.model}, voice=#{config.voice}, language=#{config.language}, " <>
        "silence=#{config.silence_duration_ms}ms)"
    )

    case provider.open(
           owner: self(),
           model: config.model,
           voice: config.voice,
           language: config.language,
           silence_duration_ms: config.silence_duration_ms
         ) do
      {:ok, session} ->
        Logger.info("live session open")
        {:ok, %{session: session, provider: provider}}

      {:error, reason} ->
        Logger.error("failed to open live session: #{inspect(reason)}")
        # Close, don't linger. A socket left alive with session: nil sends every later
        # binary frame into the no-op clause below, and the browser's continuous mic
        # traffic keeps resetting the idle timeout — so it would never close on its own.
        {:stop, :normal, 1011, error_frame(reason), %{session: nil, provider: provider}}
    end
  end

  # ---------------------------------------------------------------- upstream

  @impl WebSock
  def handle_in({pcm, [opcode: :binary]}, %{session: session, provider: provider} = state)
      when session != nil do
    # THE GOTCHA THAT SURVIVES: live mic audio is a STREAM. Both APIs have a separate
    # call for seeding conversation history, and using that one for the mic means the
    # turn never fires. Dead air. Providers send it as realtime input.
    case provider.send_audio(session, pcm) do
      :ok ->
        {:ok, state}

      {:error, reason} ->
        Logger.warning("send_audio failed: #{inspect(reason)}")
        {:ok, state}
    end
  end

  # The frontend never sends text frames today; the contract reserves them for
  # `{"type":"start"|"stop"}`, so accept and ignore rather than crash.
  def handle_in({_data, [opcode: :text]}, state), do: {:ok, state}
  def handle_in(_frame, state), do: {:ok, state}

  # -------------------------------------------------------------- downstream

  # Voice is the only event worth dropping, and the only one that arrives fast enough to
  # matter. The provider pushes it with plain send/2, which never blocks the sender, while
  # a browser that has stopped reading can hold this process inside one write for the
  # whole send_timeout. That is the unbounded-growth path, and shedding is the right
  # answer for LIVE audio specifically: a frame that arrives late is worth nothing anyway.
  # Transcripts, actions and errors are never shed — they are small, and they are the
  # events that explain what happened.
  @max_queued 40

  @impl WebSock
  def handle_info({:provider, {:voice, pcm}}, state) do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, queued} when queued > @max_queued ->
        Logger.warning("dropping voice frame, #{queued} messages queued — browser not draining")
        {:ok, state}

      _ ->
        {:push, [{:binary, pcm}], state}
    end
  end

  def handle_info({:provider, :interrupted}, state) do
    {:push, json(%{type: "interrupted"}), state}
  end

  def handle_info({:provider, {:transcript, role, text}}, state) do
    {:push, json(%{type: "transcript", role: transcript_role(role), text: text}), state}
  end

  # A tool call decided something; forward it to the browser's activity panel.
  def handle_info({:provider, {:action, command}}, state) do
    {:push, json(Map.put(command, :type, "action")), state}
  end

  def handle_info({:provider, {:error, reason}}, state) do
    Logger.error("live session error: #{inspect(reason)}")
    {:push, error_frame(reason), state}
  end

  def handle_info({:provider, {:closed, reason}}, state) do
    Logger.info("live session closed: #{inspect(reason)}")
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, pid, reason}, %{session: pid} = state) do
    Logger.error("live session process exited: #{inspect(reason)}")
    {:stop, :normal, %{state | session: nil}}
  end

  def handle_info(msg, state) do
    Logger.debug("socket: unhandled message #{inspect(msg)}")
    {:ok, state}
  end

  @impl WebSock
  def terminate(reason, %{session: session, provider: provider}) do
    Logger.info("ws closed (#{inspect(reason)})")
    if session, do: provider.close(session)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ----------------------------------------------------------------- private

  defp transcript_role(:user), do: "user"
  defp transcript_role(:ceci), do: "ceci"

  # The browser is untrusted, and an upstream reason can carry quota/billing state or a
  # URL with the API key in it. The detail stays in the log — both call sites log it —
  # and the client gets a fixed string.
  defp error_frame(_reason) do
    json(%{type: "error", message: "a linha caiu — tente de novo"})
  end

  # WebSock takes a list of frames; keeping every builder list-shaped makes them
  # composable with `++`.
  defp json(payload), do: [{:text, Jason.encode!(payload)}]
end
