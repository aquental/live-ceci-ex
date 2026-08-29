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

  ## Two bounds nothing else was applying

  Bandit's WebSocket `:timeout` is an IDLE timeout — it is passed through as
  ThousandIsland's `{:persistent, timeout}` and resets on every frame read — and an open
  microphone sends ten frames a second, so it never fired. A tab left open on a second
  monitor held an upstream session, billed by the minute, until the laptop slept.

  So a session now has a wall clock and a byte budget, both in `LiveCeci.Limits`. Two
  bounds rather than one because they catch different things: the clock catches the
  forgotten tab, and the budget catches a client sending faster than real time, which
  the clock alone would happily let run for its full fifteen minutes.

  A third bound sits alongside them and is not about volume at all. `end_of_speech` is
  thirty bytes that become a billed model response upstream, so metering bytes does not
  meter it — a security audit found the loop: one session, one text frame repeated,
  fifteen minutes of responses. `@min_commit_interval_ms` is the floor. A person cannot
  end a sentence four times a second, and the model's own answer takes about a second, so
  the floor costs nothing a real client would notice.

  Both volume bounds end the same way — an `error` frame the browser already renders, then a normal
  close. The page turns its button into "↻ reconectar" and the person carries on.

  ## The wire contract

  Browser -> server: binary frames of 16 kHz mono PCM s16le, plus one JSON text frame:
    `{"type":"end_of_speech"}`   the client's gate says the turn is over (manual mode)
  Server -> browser: binary frames of 24 kHz PCM (voice), plus JSON text frames:
    `{"type":"transcript","role":"user"|"ceci","text":...}`
    `{"type":"action","action":"agendar"|"presenca"|"recibo"|"resumo","detail":...}`
    `{"type":"interrupted"}`
    `{"type":"error","message":...}`
  """

  @behaviour WebSock

  require Logger

  alias LiveCeci.{Provider, Redact}

  @impl WebSock
  def init(opts) do
    # Before anything else, and before provider.open/1 in particular: past this line a
    # session exists upstream and is billed. Refusing after opening it would cost exactly
    # what the cap is here to prevent.
    #
    # The slot is held by THIS process and released by the Registry when it dies, so
    # there is nothing for terminate/2 to remember.
    case LiveCeci.Sessions.join(Keyword.get(opts, :address, {127, 0, 0, 1})) do
      :ok -> open_session()
      {:error, :too_many_sessions} -> refuse()
    end
  end

  # 1013 Try Again Later, not 1011 Internal Error: the connection was refused, and
  # nothing went wrong.
  defp refuse do
    {:stop, :normal, 1013,
     json(%{type: "error", message: "muitas conexões — tente daqui a pouco"}),
     %{session: nil, provider: nil, bytes: 0, last_commit: nil}}
  end

  defp open_session do
    # Trap exits so a provider crash becomes a message we can report to the browser,
    # instead of silently taking this process down with it.
    Process.flag(:trap_exit, true)

    config = LiveCeci.config()
    provider = Provider.current()

    Logger.info(
      "ws connected; opening #{Redact.inspect(provider)} session " <>
        "(model=#{config.model}, voice=#{config.voice}, language=#{config.language}, " <>
        "silence=#{config.silence_duration_ms}ms, turns=#{config.turn_detection})"
    )

    case provider.open(
           owner: self(),
           model: config.model,
           voice: config.voice,
           language: config.language,
           silence_duration_ms: config.silence_duration_ms,
           turn_detection: config.turn_detection
         ) do
      {:ok, session} ->
        # So the cap can close it if this process dies without terminate/2 running.
        LiveCeci.Sessions.attach(provider, session)
        # The wall clock. send_after rather than a timeout on this callback, because
        # every WebSock timeout available here is an idle one and this must fire whether
        # or not the microphone is talking.
        Process.send_after(self(), :session_expired, LiveCeci.Limits.session_lifetime_ms())
        Logger.info("live session open")
        {:ok, %{session: session, provider: provider, bytes: 0, last_commit: nil}}

      {:error, reason} ->
        Logger.error("failed to open live session: #{Redact.inspect(reason)}")
        # Close, don't linger. A socket left alive with session: nil sends every later
        # binary frame into the no-op clause below, and the browser's continuous mic
        # traffic keeps resetting the idle timeout — so it would never close on its own.
        {:stop, :normal, 1011, error_frame(reason),
         %{session: nil, provider: provider, bytes: 0, last_commit: nil}}
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
        spent(state, byte_size(pcm))

      {:error, reason} ->
        Logger.warning("send_audio failed: #{Redact.inspect(reason)}")
        # Not counted. A frame the provider refused cost nothing upstream, and charging
        # for it would let a stalled session close itself early.
        {:ok, state}
    end
  end

  # The one text frame the browser sends. In manual turn mode the client's own gate
  # decides when you stopped talking, and this is how it says so; the provider turns it
  # into whatever its protocol needs. Under server VAD it is a no-op on both sides, so
  # the frontend can send it unconditionally and neither end has to know the mode.
  def handle_in({data, [opcode: :text]}, %{session: session, provider: provider} = state)
      when session != nil do
    state =
      case Jason.decode(data) do
        {:ok, %{"type" => "end_of_speech"}} -> maybe_commit(state, provider, session)
        _ -> state
      end

    # Text is charged too. A text frame costs the provider nothing directly, but it costs
    # US the read and the decode, and Bandit's max_frame_size is a megabyte — so a budget
    # that only counted audio was a budget with a door next to it.
    spent(state, byte_size(data))
  end

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

  # The wall clock. Deliberately not a silent disconnect: the browser is told why, in the
  # frame it already knows how to render, and its own onclose turns the button into
  # "↻ reconectar". Fifteen minutes is a long conversation, and starting a new one costs
  # a click.
  def handle_info(:session_expired, state) do
    Logger.info("closing session: lifetime reached")

    {:stop, :normal, 1000,
     json(%{type: "error", message: "sessão encerrada por tempo — toque para recomeçar"}), state}
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
    Logger.error("live session error: #{Redact.inspect(reason)}")
    {:push, error_frame(reason), state}
  end

  def handle_info({:provider, {:closed, reason}}, state) do
    Logger.info("live session closed: #{Redact.inspect(reason)}")
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, pid, reason}, %{session: pid} = state) do
    Logger.error("live session process exited: #{Redact.inspect(reason)}")
    {:stop, :normal, %{state | session: nil}}
  end

  def handle_info(msg, state) do
    Logger.debug("socket: unhandled message #{Redact.inspect(msg)}")
    {:ok, state}
  end

  @impl WebSock
  def terminate(reason, %{session: session, provider: provider}) do
    Logger.info("ws closed (#{Redact.inspect(reason)})")
    if session, do: provider.close(session)
    :ok
  end

  # ----------------------------------------------------------------- private

  # A quarter of a second. A person cannot end a sentence four times a second, the
  # model's own answer takes about a second, and the browser's gate fires on a falling
  # edge that has a silence budget behind it — so nothing legitimate is ever this close
  # together. Below the floor the frame is dropped silently rather than answered with an
  # error: a client that is merely early is not doing anything wrong.
  @min_commit_interval_ms 250

  defp maybe_commit(state, provider, session) do
    now = System.monotonic_time(:millisecond)

    if state.last_commit == nil or now - state.last_commit >= @min_commit_interval_ms do
      provider.commit_turn(session)
      %{state | last_commit: now}
    else
      state
    end
  end

  # The byte budget, checked where the bytes are. Counting on the way out rather than on
  # the way in means a client that floods faster than the provider drains is bounded by
  # what actually reached the provider, which is the thing being billed.
  defp spent(state, bytes) do
    total = state.bytes + bytes

    if total > LiveCeci.Limits.session_byte_budget() do
      Logger.info("closing session: byte budget spent (#{total} bytes)")

      {:stop, :normal, 1000,
       json(%{type: "error", message: "sessão encerrada — limite de áudio atingido"}),
       %{state | bytes: total}}
    else
      {:ok, %{state | bytes: total}}
    end
  end

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
