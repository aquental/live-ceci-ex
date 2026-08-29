defmodule LiveCeci.Provider do
  @moduledoc """
  The seam between `LiveCeci.Socket` and whichever live-voice API is behind it.

  Two APIs sit behind this today — Gemini Live and xAI's Voice Agent — and they
  disagree about almost everything at the wire level: Gemini pushes typed structs
  through callbacks and takes audio by reference, Grok speaks a JSON event protocol
  over a raw WebSocket and takes audio base64-encoded. Neither vocabulary is a good
  lingua franca, so providers translate into the small neutral set below and the
  socket never learns which one it is talking to.

  ## What a provider sends its owner

      {:provider, {:voice, pcm}}                       # 24 kHz s16le, already decoded
      {:provider, :interrupted}                        # drop whatever audio is queued
      {:provider, {:transcript, :user | :ceci, text}}
      {:provider, {:action, command}}                  # a tool decided something to show
      {:provider, {:error, reason}}
      {:provider, {:closed, reason}}

  Decoding belongs to the provider: by the time a frame reaches the socket it is raw
  PCM, not base64 and not a struct.

  ## Why tool dispatch lives in the provider

  There is no honest way to lift it out. `gemini_ex` hands a tool call to a callback
  and expects the result as its RETURN value, synchronously; xAI expects two separate
  messages sent back over the socket. A shared `send_tool_result/3` would fit one and
  be dead weight in the other, and routing tool calls through the socket process would
  make the Gemini path impossible. So each provider calls `LiveCeci.Tools.dispatch/2`
  itself and emits `{:action, command}` — the decision stays shared, only the handshake
  differs.

  Both APIs pause the model's voice until the result comes back, which is why
  `dispatch/2` returns in microseconds and has a test guarding that.
  """

  @typedoc "Whatever the provider uses to address one open session."
  @type session :: pid()

  @doc """
  Opens a session and connects it. `opts` carries `:owner`, `:model` and `:voice`.

  The session is linked to the caller, so one that dies takes the socket's
  `trap_exit` path rather than disappearing quietly.
  """
  @callback open(keyword()) :: {:ok, session()} | {:error, term()}

  @doc """
  Sends one frame of 16 kHz mono PCM s16le upstream.

  Called once per ~100 ms of microphone audio, on the socket process, so it must
  return promptly and must never let an upstream stall exit the caller.
  """
  @callback send_audio(session(), binary()) :: :ok | {:error, term()}

  @doc """
  Signals that the user stopped talking, when the provider's own VAD is turned off.

  Only meaningful in manual turn mode. Measured on xAI, three reps interleaved against a
  fixed utterance: 1818 ms median from end of speech to first byte of voice with
  `server_vad`, 985 ms with the turn closed explicitly. The silence budget stops being a
  floor under every answer and becomes whatever the browser's own gate decides.

  What it buys in latency it risks in false turns: the client is now the thing that
  decides you finished a sentence, and it can be wrong. A provider that keeps server VAD
  ignores this call.
  """
  @callback commit_turn(session()) :: :ok

  @doc "Closes the session. Must tolerate an already-dead session."
  @callback close(session()) :: :ok

  @doc """
  The provider module for this run.

  Read at call time, not compile time, so `MODEL` in `.env` picks the backend without a
  recompile. `config/config.exs` holds the default and `config/runtime.exs` overrides it
  from `MODEL`; `MODEL=GOOGLE` selects Gemini Live.

  The default lives in config rather than as a fallback argument here. Naming
  `LiveCeci.Provider.Grok` in this function made the seam depend on one of the things
  behind it, which `mix xref --format cycles` reported as a two-node cycle: the
  behaviour pointing at an implementation that points back at the behaviour. It was
  runtime-only and cost nothing, but a seam that names a specific backend is the kind of
  wrong that stops being free the day a third provider arrives.
  """
  @spec current() :: module()
  def current, do: Application.get_env(:live_ceci, :provider)
end
