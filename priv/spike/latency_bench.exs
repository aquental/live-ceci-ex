# Bench: how long does each backend take to answer?
#
#     set -a && . ./.env && set +a && mix run --no-start priv/spike/latency_bench.exs
#
# Measures ONE number, because only one is comparable across the two APIs:
#
#     TTFA — from the last byte of the user's utterance to the first byte of voice back.
#
# The transcripts are not comparable and this deliberately does not race them. Gemini
# streams the assistant transcript in fragments while she is still speaking; xAI sends
# `response.output_audio_transcript.done` only once the whole text exists. Timing
# "first transcript" would measure the granularity of the protocol and hand Google a
# few hundred milliseconds it did not earn. The user transcript is recorded here purely
# as a did-the-audio-arrive check, and printed as diagnostics, never as a comparison.
#
# ## Why it starts its own server
#
# The provider is chosen by `LiveCeci.Provider.current/0`, which reads application env
# at call time. Running the listener in THIS process means a trial can flip the backend
# between connections — so GROK and GOOGLE trials can be interleaved. That matters more
# than it sounds: running eight of one and then eight of the other makes any drift in
# the route to us indistinguishable from a difference between the models.
#
# ## What is deliberately not controlled
#
# Network distance to each POP. api.x.ai and generativelanguage.googleapis.com are
# different hosts and this cannot separate their RTT from the model's thinking time.
# The connect column is the closest thing to a floor for each.

defmodule LatencyBench.Client do
  @moduledoc false
  # A browser, minus the browser. Timestamps every frame the server pushes and forwards
  # it to the bench process; the bench does all the deciding.
  use WebSockex

  def start(url, owner), do: WebSockex.start_link(url, __MODULE__, %{owner: owner})

  @impl true
  def handle_frame({:binary, pcm}, state) do
    send(state.owner, {:voice, mono(), byte_size(pcm)})
    {:ok, state}
  end

  def handle_frame({:text, raw}, state) do
    case Jason.decode(raw) do
      {:ok, event} -> send(state.owner, {:event, mono(), event})
      # Never crash the client on a malformed frame: it would take the trial with it
      # and the run would report a timeout instead of a decode problem.
      {:error, _} -> :ok
    end

    {:ok, state}
  end

  def handle_frame(_frame, state), do: {:ok, state}

  @impl true
  def handle_cast(:close, state), do: {:close, state}

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    send(state.owner, {:closed, reason})
    {:ok, state}
  end

  defp mono, do: System.monotonic_time(:millisecond)
end

defmodule LatencyBench do
  @moduledoc false

  @wav Path.join(__DIR__, "bench_utterance.wav")
  @utterance "Oi Mira, tudo bem? Me conta uma coisa rápida sobre você."
  @say_voice "Luciana"

  # Sent before the utterance so the trial does not start mid-handshake. Bandit answers
  # the upgrade with 101 BEFORE LiveCeci.Socket.init/1 runs, so a connected client is not
  # yet a connected provider session — the socket process is still opening it. Frames
  # sent in that window are not lost (the process handles init/1 before any handle_in/2)
  # but they would arrive compressed into one burst, and a VAD fed a compressed timeline
  # produces a number that means nothing.
  @session_grace_ms 1_200
  @lead_in_ms 500

  @first_audio_timeout 20_000
  @between_trials_ms 1_500

  # No key, no trials. Reported rather than skipped silently, so a half-run is obvious.
  @backends [
    %{
      name: "GROK",
      module: LiveCeci.Provider.Grok,
      model: {"GROK_LIVE_MODEL", "grok-voice-latest"},
      voice: {"GROK_LIVE_VOICE", "eve"}
    },
    %{
      name: "GOOGLE",
      module: LiveCeci.Provider.Gemini,
      model: {"GOOGLE_LIVE_MODEL", "gemini-3.1-flash-live-preview"},
      voice: {"GOOGLE_LIVE_VOICE", "Aoede"}
    }
  ]

  def run do
    start_apps()

    config = LiveCeci.config()
    trials = LiveCeci.env_int("BENCH_TRIALS", 8, 1..100)
    pcm = utterance_pcm()
    frame_bytes = config.frame_samples * 2

    header(config, trials, pcm, frame_bytes)

    case Enum.filter(@backends, &available?/1) do
      [] ->
        IO.puts("No API keys in the environment. Set GROK_API_KEY and/or GOOGLE_API_KEY.")

      backends ->
        port = start_server()
        results = measure(port, backends, trials, pcm, frame_bytes)
        report(results)
    end
  end

  # ---- the run ----------------------------------------------------------------

  # Interleaved, not blocked: one trial of each backend per round. If the route to us
  # degrades halfway through, it degrades for both and the comparison survives.
  defp measure(port, backends, trials, pcm, frame_bytes) do
    IO.puts("warm-up (discarded) …")
    for b <- backends, do: trial(port, b, pcm, frame_bytes)

    IO.puts("")

    Enum.reduce(1..trials, %{}, fn round, acc ->
      Enum.reduce(backends, acc, fn backend, acc ->
        result = trial(port, backend, pcm, frame_bytes)
        IO.puts("  #{pad(backend.name, 7)} #{pad("##{round}", 4)} #{describe(result)}")
        Map.update(acc, backend.name, [result], &[result | &1])
      end)
    end)
  end

  defp trial(port, backend, pcm, frame_bytes) do
    Application.put_env(:live_ceci, :provider, backend.module)
    Application.put_env(:live_ceci, :model, env(backend.model))
    Application.put_env(:live_ceci, :voice, env(backend.voice))

    t_connect = mono()

    case LatencyBench.Client.start("ws://127.0.0.1:#{port}/ws", self()) do
      {:ok, ws} ->
        connect_ms = mono() - t_connect
        Process.sleep(@session_grace_ms)

        stream(ws, silence(@lead_in_ms), frame_bytes)
        stream(ws, pcm, frame_bytes)
        t0 = mono()

        # Anything already in the mailbox predates the utterance — a greeting, or an
        # interruption we caused by talking over one. It is not an answer to this turn.
        drain()

        result = await_first_audio(ws, t0, frame_bytes)

        WebSockex.cast(ws, :close)
        Process.sleep(@between_trials_ms)
        drain()

        Map.put(result, :connect_ms, connect_ms)

      {:error, reason} ->
        %{ttfa_ms: nil, error: inspect(reason), connect_ms: nil, user_transcript_ms: nil}
    end
  end

  # Paced against absolute deadlines rather than sleeping frame_ms per iteration: the
  # sleep and the send both take time, and at ~10 frames a second that drift compounds
  # into an utterance the VAD hears as slower than real speech.
  defp stream(ws, pcm, frame_bytes) do
    frame_ms = frame_bytes / 2 / 16
    start = mono()

    pcm
    |> chunks(frame_bytes)
    |> Enum.with_index()
    |> Enum.each(fn {chunk, i} ->
      WebSockex.send_frame(ws, {:binary, chunk})
      sleep_until(start + round((i + 1) * frame_ms))
    end)
  end

  # The clock starts at the last frame of speech, but the microphone does NOT stop
  # there — and that distinction is the whole reason this function pads.
  #
  # A first version simply waited here, and every trial against both backends timed out
  # at 20 s. Server VAD does not close a turn on the ABSENCE of frames; it closes it on
  # hearing enough silence, and a client that stops sending gives it nothing to hear. A
  # browser never stops: the worklet keeps shipping whatever the room sounds like. So
  # this keeps the stream alive at the same cadence, and polls between frames so audio
  # that lands mid-pad is timed when it lands rather than at the end of a padding loop.
  defp await_first_audio(ws, t0, frame_bytes) do
    pad = :binary.copy(<<0, 0>>, div(frame_bytes, 2))
    frame_ms = max(1, round(frame_bytes / 2 / 16))
    deadline = t0 + @first_audio_timeout

    pump(ws, pad, frame_ms, deadline, t0, %{ttfa_ms: nil, user_transcript_ms: nil, error: nil})
  end

  defp pump(ws, pad, frame_ms, deadline, t0, acc) do
    case poll(acc, t0) do
      %{ttfa_ms: ttfa} = done when not is_nil(ttfa) ->
        done

      %{error: error} = done when not is_nil(error) ->
        done

      acc ->
        if mono() >= deadline do
          Map.put(acc, :error, "no audio within #{@first_audio_timeout} ms")
        else
          send_pad(ws, pad)
          Process.sleep(frame_ms)
          pump(ws, pad, frame_ms, deadline, t0, acc)
        end
    end
  end

  defp poll(acc, t0) do
    receive do
      {:voice, at, _bytes} ->
        Map.put(acc, :ttfa_ms, at - t0)

      # Diagnostics only. Never compared across backends — see the module header. Its
      # real job is telling "the model had nothing to say" apart from "the model never
      # heard us", which look identical from a timeout.
      {:event, at, %{"type" => "transcript", "role" => "user"}} ->
        poll(%{acc | user_transcript_ms: acc.user_transcript_ms || at - t0}, t0)

      {:event, _at, %{"type" => "error", "message" => message}} ->
        Map.put(acc, :error, message)

      {:closed, reason} ->
        Map.put(acc, :error, "closed: #{inspect(reason)}")

      _other ->
        poll(acc, t0)
    after
      0 -> acc
    end
  end

  # The socket can go away mid-pad; that is a finished trial, not a crash.
  defp send_pad(ws, pad) do
    WebSockex.send_frame(ws, {:binary, pad})
  catch
    :exit, _reason -> :ok
  end

  # ---- reporting ---------------------------------------------------------------

  defp header(config, trials, pcm, frame_bytes) do
    seconds = Float.round(byte_size(pcm) / 2 / 16_000, 2)

    IO.puts("""

    latency bench — TTFA, from the end of the utterance to the first byte of voice

      silence_duration_ms  #{config.silence_duration_ms}   (a hard floor under every number below)
      frame_samples        #{config.frame_samples}   = #{Float.round(frame_bytes / 2 / 16, 1)} ms per frame
      language             #{inspect(config.language)}
      utterance            #{seconds}s  #{Path.relative_to_cwd(@wav)}
      trials               #{trials} per backend, interleaved
    """)
  end

  defp describe(%{ttfa_ms: nil} = r), do: "—        #{r.error}#{heard(r)}"
  defp describe(%{ttfa_ms: ttfa} = r), do: "#{pad("#{ttfa} ms", 9)}#{heard(r)}"

  # Without this a failed trial cannot be read. "no audio" with a transcript means the
  # model heard the question and chose not to answer it; "no audio" without one means
  # the audio never landed, which is a bug here, not a result.
  defp heard(%{user_transcript_ms: nil}), do: "   (no user transcript — audio never landed)"
  defp heard(%{user_transcript_ms: ms}), do: "   (heard at #{ms} ms)"

  defp report(results) do
    IO.puts("""

    #{pad("backend", 9)}#{pad("n", 5)}#{pad("p50", 9)}#{pad("p95", 9)}#{pad("min", 9)}#{pad("max", 9)}#{pad("connect p50", 12)}
    #{String.duplicate("-", 62)}\
    """)

    for {name, trials} <- results do
      ttfa = trials |> Enum.map(& &1.ttfa_ms) |> Enum.reject(&is_nil/1) |> Enum.sort()
      connect = trials |> Enum.map(& &1.connect_ms) |> Enum.reject(&is_nil/1) |> Enum.sort()
      failures = length(trials) - length(ttfa)

      if ttfa == [] do
        IO.puts("#{pad(name, 9)}#{pad("0", 5)}every trial failed — see the lines above")
      else
        IO.puts(
          "#{pad(name, 9)}#{pad("#{length(ttfa)}", 5)}" <>
            "#{pad("#{pct(ttfa, 50)} ms", 9)}#{pad("#{pct(ttfa, 95)} ms", 9)}" <>
            "#{pad("#{hd(ttfa)} ms", 9)}#{pad("#{List.last(ttfa)} ms", 9)}" <>
            "#{pad("#{pct(connect, 50)} ms", 12)}" <>
            if(failures > 0, do: "  (#{failures} failed)", else: "")
        )
      end
    end

    IO.puts("""

    Read it as a comparison, not an absolute: #{"silence_duration_ms"} is added to every
    number and is identical on both sides, so it compresses the relative difference.
    """)
  end

  defp pct(sorted, p) do
    n = length(sorted)
    Enum.at(sorted, min(n - 1, max(0, round(p / 100 * n) - 1)))
  end

  # ---- audio -------------------------------------------------------------------

  # Generated rather than committed: it is a 50 KB binary that `say` reproduces exactly,
  # and pinning it in git would mean reviewing a blob on every change. BENCH_WAV points
  # at your own recording — 16 kHz mono s16le, which is what the browser sends.
  defp utterance_pcm do
    path = System.get_env("BENCH_WAV") || @wav
    unless File.exists?(path), do: generate_wav(path)
    parse_wav(File.read!(path), path)
  end

  defp generate_wav(path) do
    IO.puts("generating #{Path.relative_to_cwd(path)} with `say` …")

    args = [
      "-v",
      @say_voice,
      "--data-format=LEI16@16000",
      "--file-format=WAVE",
      "-o",
      path,
      @utterance
    ]

    case System.cmd("say", args, stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, code} ->
        die("""
        `say` failed (exit #{code}): #{String.trim(output)}

        It is macOS-only. On anything else, record #{Path.relative_to_cwd(path)} yourself
        as 16 kHz mono s16le WAV, or point BENCH_WAV at a file you already have.
        """)
    end
  end

  # Enough of RIFF to refuse the wrong file loudly. A 44.1 kHz or stereo WAV would stream
  # perfectly happily and be heard as gibberish, and the run would report a timeout.
  defp parse_wav(<<"RIFF", _size::little-32, "WAVE", rest::binary>>, path) do
    chunks = wav_chunks(rest, %{})

    with %{"fmt " => <<1::little-16, 1::little-16, 16_000::little-32, _::binary>>} <- chunks,
         %{"data" => data} <- chunks do
      data
    else
      _ ->
        die("#{path} is not 16 kHz mono PCM s16le. Convert it, or delete it to regenerate.")
    end
  end

  defp parse_wav(_other, path), do: die("#{path} is not a RIFF/WAVE file.")

  defp wav_chunks(<<id::binary-4, size::little-32, body::binary-size(size), rest::binary>>, acc) do
    # Chunks are word-aligned: an odd size carries a pad byte the length does not count.
    rest = if rem(size, 2) == 1, do: binary_part(rest, 1, byte_size(rest) - 1), else: rest
    wav_chunks(rest, Map.put_new(acc, id, body))
  end

  defp wav_chunks(_trailing, acc), do: acc

  defp silence(ms), do: :binary.copy(<<0, 0>>, div(ms * 16_000, 1_000))

  defp chunks(binary, size) do
    Stream.unfold(binary, fn
      <<>> -> nil
      rest when byte_size(rest) <= size -> {rest, <<>>}
      <<chunk::binary-size(^size), rest::binary>> -> {chunk, rest}
    end)
  end

  # ---- plumbing ----------------------------------------------------------------

  defp start_apps do
    for app <- [:jason, :websockex, :bandit, :gemini_ex] do
      {:ok, _} = Application.ensure_all_started(app)
    end
  end

  # Listen on 0, ask which port the OS picked, hand it back. Racy in principle and
  # entirely fine here: nothing else on this machine is hunting for the same port in
  # the microseconds between close and re-listen.
  defp start_server do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    {:ok, _pid} = Bandit.start_link(plug: LiveCeci.Router, port: port)
    port
  end

  defp available?(%{name: "GROK"}), do: present?(System.get_env("GROK_API_KEY"))

  defp available?(%{name: "GOOGLE"}) do
    present?(Application.get_env(:gemini_ex, :api_key))
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp env({name, default}), do: System.get_env(name) || default

  defp drain do
    receive do
      _ -> drain()
    after
      0 -> :ok
    end
  end

  defp sleep_until(deadline) do
    case deadline - mono() do
      ms when ms > 0 -> Process.sleep(ms)
      _ -> :ok
    end
  end

  defp mono, do: System.monotonic_time(:millisecond)
  defp pad(text, width), do: String.pad_trailing(to_string(text), width)

  defp die(message) do
    IO.puts("\n#{message}")
    System.halt(1)
  end
end

LatencyBench.run()
