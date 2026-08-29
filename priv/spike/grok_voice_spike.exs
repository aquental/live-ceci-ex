# Spike: can xAI's Voice Agent stand in for Gemini Live behind LiveCeci.Socket?
#
#     set -a && . ./.env && set +a && mix run --no-start priv/spike/grok_voice_spike.exs
#
# Throwaway. It answers the questions that decide the effort, in risk order, and
# prints a verdict per question. Nothing here is meant to survive into the app.
#
# Reuses LiveCeci.Persona and LiveCeci.Tools on purpose: if the existing declarations
# do not drop straight into Grok's session.update, that is the finding.

defmodule GrokSpike.WS do
  use WebSockex

  def start(url, key, owner) do
    WebSockex.start_link(url, __MODULE__, %{owner: owner},
      extra_headers: [{"Authorization", "Bearer " <> key}]
    )
  end

  @impl true
  def handle_frame({:text, raw}, state) do
    send(state.owner, {:grok, System.monotonic_time(:millisecond), Jason.decode!(raw)})
    {:ok, state}
  end

  # With transport: "binary" the voice arrives as raw WebSocket binary frames instead
  # of base64 inside JSON — no decode, and 33% less on the wire.
  def handle_frame({:binary, bin}, state) do
    send(state.owner, {:grok_binary, System.monotonic_time(:millisecond), bin})
    {:ok, state}
  end

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    send(state.owner, {:grok_closed, reason})
    {:ok, state}
  end
end

defmodule GrokSpike do
  @endpoint "wss://api.x.ai/v1/realtime"

  def run do
    key = System.get_env("GROK_API_KEY")
    model = env("GROK_LIVE_MODEL", "grok-voice-latest")
    voice = env("GROK_LIVE_VOICE", "eve")
    language = LiveCeci.normalize_language(System.get_env("LANGUAGE"))

    if key in [nil, ""] do
      IO.puts("GROK_API_KEY is empty — nothing to talk to. Set it in .env and re-run.")
      System.halt(1)
    end

    IO.puts("model=#{model}  voice=#{voice}  language=#{inspect(language)}\n")
    url = "#{@endpoint}?model=#{model}"

    t0 = now()

    case GrokSpike.WS.start(url, key, self()) do
      {:ok, ws} ->
        ok("1. connect + auth", "#{now() - t0} ms, Bearer header accepted")
        probe_session(ws, voice, language)

      {:error, reason} ->
        fail("1. connect + auth", inspect(reason))
        IO.puts("\nEverything else depends on this. Stopping.")
    end
  end

  # ---- probes ----------------------------------------------------------------

  defp probe_session(ws, voice, language) do
    created = wait_for(["session.created"], 10_000)

    if created,
      do: ok("2. session.created", "server opened the session"),
      else: fail("2. session.created", "no session.created within 10 s")

    # The whole point: does what the app already has drop straight in?
    tools =
      Enum.map(LiveCeci.Tools.declarations(), fn d ->
        %{
          type: "function",
          name: d.name,
          description: d.description,
          parameters: d.parameters
        }
      end)

    send_json(ws, %{
      type: "session.update",
      session: %{
        voice: voice,
        # Gemini wants a Content struct here; Grok wants a plain string.
        instructions: persona_text(),
        turn_detection: %{
          type: "server_vad",
          silence_duration_ms: 500,
          # Proactive re-engagement: if the user goes quiet this long after a
          # response, the model speaks first instead of waiting forever.
          idle_timeout_ms: 8_000
        },
        audio: %{
          # The rates the browser already speaks. If these are rejected, the
          # frontend has to change and the estimate moves.
          # transport: "binary" moves audio out of JSON in both directions.
          input:
            %{format: %{type: "audio/pcm", rate: 16_000}, transport: "binary"}
            |> maybe_transcription(language),
          output: %{format: %{type: "audio/pcm", rate: 24_000}, transport: "binary"}
        },
        tools: tools
      }
    })

    case wait_for(["session.updated", "error"], 10_000) do
      %{"type" => "session.updated"} ->
        ok(
          "3. session.update",
          "persona + #{length(tools)} tools + 16k/24k PCM, binary transport, idle_timeout"
        )

      %{"type" => "error"} = e ->
        fail("3. session.update", inspect(Map.get(e, "error", e)))

      nil ->
        warn("3. session.update", "no ack — server may accept silently")
    end

    probe_text_turn(ws)
    probe_binary_input(ws)
    probe_tool_call(ws)
    probe_manual_turn(ws)
    summary()
  end

  defp probe_text_turn(ws) do
    drain(300)
    t = now()
    say(ws, "diga, em portugues, uma frase curta de boas vindas")

    # The whole point of this probe now: does the voice come back as binary frames,
    # or did the server ignore transport and fall back to base64 in JSON?
    case wait_for_audio(20_000) do
      {:binary, first} ->
        ok("4. text turn -> audio", "first audio in #{now() - t} ms, BINARY frames")
        chunks = [first | collect_binary(4_000, [])]
        report_shape(chunks)
        Process.put(:her_voice, IO.iodata_to_binary(chunks))

      {:json, b64} ->
        warn("4. text turn -> audio", "first audio in #{now() - t} ms, base64 in JSON")
        warn("   binary transport", "requested but not honoured — adapter keeps decoding")
        report_shape([Base.decode64!(b64)])

      :timeout ->
        fail("4. text turn -> audio", "no audio within 20 s")
    end
  end

  defp report_shape(chunks) do
    bytes = chunks |> IO.iodata_to_binary() |> byte_size()
    secs = Float.round(bytes / 2 / 24_000, 2)
    ok("   audio shape", "#{bytes} bytes = #{secs}s at 24 kHz s16le")
  end

  # Whichever arrives first decides the verdict above.
  defp wait_for_audio(timeout) do
    deadline = now() + timeout
    do_wait_audio(deadline)
  end

  defp do_wait_audio(deadline) do
    left = deadline - now()

    if left <= 0 do
      :timeout
    else
      receive do
        {:grok_binary, _t, bin} -> {:binary, bin}
        {:grok, _t, %{"type" => "response.output_audio.delta", "delta" => b64}} -> {:json, b64}
        {:grok, _t, _} -> do_wait_audio(deadline)
        {:grok_closed, _} -> :timeout
      after
        left -> :timeout
      end
    end
  end

  defp collect_binary(window, acc) do
    deadline = now() + window

    receive do
      {:grok_binary, _t, bin} -> collect_binary(deadline - now(), [bin | acc])
      _ -> collect_binary(deadline - now(), acc)
    after
      max(window, 0) -> Enum.reverse(acc)
    end
  end

  defp maybe_transcription(input, nil), do: input

  defp maybe_transcription(input, language),
    do: Map.put(input, :transcription, %{language_hint: language})

  # Probe 4 proved binary OUTPUT. This proves binary INPUT, which is the half that
  # decides whether the adapter can stop base64-encoding every 100 ms mic frame.
  # Her own voice is the only real speech on hand, so it goes back up resampled.
  defp probe_binary_input(ws) do
    case Process.get(:her_voice) do
      nil ->
        warn("7. binary input", "skipped — no captured audio to send")

      pcm24 ->
        pcm16 = downsample_24k_to_16k(pcm24)
        drain(500)

        # Real-time pacing, as the browser does.
        for <<chunk::binary-3200 <- pcm16>> do
          WebSockex.send_frame(ws, {:binary, chunk})
          Process.sleep(100)
        end

        for _ <- 1..12 do
          WebSockex.send_frame(ws, {:binary, :binary.copy(<<0, 0>>, 1600)})
          Process.sleep(100)
        end

        case wait_for(["conversation.item.input_audio_transcription.updated", "error"], 15_000) do
          %{"type" => "error"} = e ->
            fail("7. binary input", inspect(Map.get(e, "error", e)))

          %{"transcript" => t} ->
            ok("7. binary input", "transcribed: #{inspect(String.slice(t, 0, 40))}")

          nil ->
            fail("7. binary input", "frames accepted but nothing transcribed in 15 s")
        end
    end
  end

  # 24k -> 16k is a ratio of 1.5. Linear interpolation, not nearest-neighbour: a naive
  # decimation aliases badly enough that the model hears noise and answers nothing.
  defp downsample_24k_to_16k(pcm) do
    src = for <<x::little-signed-16 <- pcm>>, do: x
    arr = :array.from_list(src)
    n = length(src)
    out = trunc(n / 1.5)

    for i <- 0..(out - 1), into: <<>> do
      pos = i * 1.5
      lo = trunc(pos)
      hi = min(lo + 1, n - 1)
      frac = pos - lo
      v = :array.get(lo, arr) * (1 - frac) + :array.get(hi, arr) * frac
      <<trunc(v)::little-signed-16>>
    end
  end

  defp probe_tool_call(ws) do
    drain(500)
    t = now()
    say(ws, "toca uma musica rapida")

    case wait_for(["response.function_call_arguments.done"], 20_000) do
      %{"name" => name, "call_id" => id, "arguments" => args} ->
        ok("5. tool call", "#{name}(#{args}) in #{now() - t} ms")

        # Gemini needs one message here. Grok needs two — this is the friction.
        send_json(ws, %{
          type: "conversation.item.create",
          item: %{type: "function_call_output", call_id: id, output: ~s({"result":"ok"})}
        })

        send_json(ws, %{type: "response.create"})

        case wait_for_audio(20_000) do
          :timeout ->
            fail("6. tool result -> voice resumes", "no audio after function_call_output")

          _ ->
            ok("6. tool result -> voice resumes", "two-message handshake works")
        end

      _ ->
        fail("5. tool call", "model never called a tool — check the declarations shape")
    end
  end

  # ---- manual turn detection --------------------------------------------------
  #
  # Documented at docs.x.ai: turn_detection.type accepts "server_vad" or null, and
  # `input_audio_buffer.commit` "is only available when turn_detection type is null".
  # So the manual path exists. The question these two probes answer is whether it is
  # FASTER, which the docs do not say and cannot say — with server VAD the model waits
  # silence_duration_ms before it will admit the turn ended, and with manual turns that
  # wait is replaced by whatever the client's own VAD decides.
  #
  # Both halves stream the SAME audio at the same pace, and both start the clock at the
  # last frame of speech. The only difference is what happens next: padding silence and
  # waiting, versus commit + response.create immediately.

  @silence_frame :binary.copy(<<0, 0>>, 1600)

  defp probe_manual_turn(ws) do
    case Process.get(:her_voice) do
      nil ->
        warn("8. manual turn accepted", "skipped — no captured audio to send")
        warn("9. manual vs server_vad", "skipped — no captured audio to send")

      pcm24 ->
        pcm16 = downsample_24k_to_16k(pcm24)

        vad_ms = measure_server_vad(ws, pcm16)

        if switch_turn_detection(ws, nil) do
          measure_manual(ws, pcm16, vad_ms)
        end
    end
  end

  # Probe 8 on its own: does the server take a null type at all? A rejection here ends
  # the question, and it is worth telling apart from "accepted but no faster".
  defp switch_turn_detection(ws, nil) do
    drain(300)
    send_json(ws, %{type: "session.update", session: %{turn_detection: %{type: nil}}})

    case wait_for(["session.updated", "error"], 10_000) do
      %{"type" => "session.updated"} ->
        ok("8. manual turn accepted", ~s(turn_detection.type = null, mid-session))
        true

      %{"type" => "error"} = e ->
        fail("8. manual turn accepted", inspect(Map.get(e, "error", e)))
        false

      nil ->
        warn("8. manual turn accepted", "no ack either way")
        false
    end
  end

  defp switch_turn_detection(ws, :server_vad) do
    drain(300)

    send_json(ws, %{
      type: "session.update",
      session: %{turn_detection: %{type: "server_vad", silence_duration_ms: 500}}
    })

    wait_for(["session.updated", "error"], 10_000)
  end

  defp measure_server_vad(ws, pcm16) do
    switch_turn_detection(ws, :server_vad)
    settle()
    stream_speech(ws, pcm16)
    t0 = now()
    flush()

    # The browser never stops sending; the VAD needs to hear the silence to close the
    # turn. Padding continues WHILE waiting, so audio that arrives mid-pad is timed when
    # it arrives rather than after the padding loop finishes.
    case await_audio_padding(ws, 30) do
      nil ->
        fail("9. manual vs server_vad", "server_vad produced no audio — nothing to compare")
        nil

      _ ->
        now() - t0
    end
  end

  defp measure_manual(ws, pcm16, vad_ms) do
    settle()
    stream_speech(ws, pcm16)
    t0 = now()
    flush()

    # No padding and no waiting: the turn is over because we say it is.
    send_json(ws, %{type: "input_audio_buffer.commit"})
    send_json(ws, %{type: "response.create"})

    case wait_for_audio(20_000) do
      nil ->
        fail("9. manual vs server_vad", "commit + response.create produced no audio in 20 s")

      _ ->
        manual_ms = now() - t0
        verdict(manual_ms, vad_ms)
    end
  end

  # The first run of this probe reported server_vad at 0 ms, which is not a fast model:
  # it is Mira still talking from probe 6, plus whatever she said mid-utterance when her
  # own voice was streamed back at her. Both are answers to an EARLIER turn sitting in
  # the mailbox. settle/0 and flush/0 remove them; this clause exists because if they
  # ever stop working, an impossible number must read as broken and not as a result.
  defp verdict(_manual_ms, vad_ms) when is_integer(vad_ms) and vad_ms < 200 do
    fail(
      "9. manual vs server_vad",
      "server_vad answered in #{vad_ms} ms — that is leftover audio, not a turn. Discarded."
    )
  end

  defp verdict(manual_ms, nil) do
    warn("9. manual vs server_vad", "manual #{manual_ms} ms; no server_vad number to compare")
  end

  defp verdict(manual_ms, vad_ms) do
    saved = vad_ms - manual_ms
    detail = "manual #{manual_ms} ms vs server_vad #{vad_ms} ms (#{saved} ms)"

    # One sample each. It answers "is this worth building", not "how much faster".
    if saved > 150 do
      ok("9. manual vs server_vad", detail <> " — worth wiring into the provider")
    else
      warn("9. manual vs server_vad", detail <> " — not obviously worth the false-turn risk")
    end
  end

  # Waits for a gap rather than a fixed delay: whatever she was saying has to actually
  # finish, and a 4 s response outlasts any constant worth hardcoding.
  defp settle, do: drain(1_200)

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end

  defp stream_speech(ws, pcm16) do
    for <<chunk::binary-3200 <- pcm16>> do
      WebSockex.send_frame(ws, {:binary, chunk})
      Process.sleep(100)
    end
  end

  defp await_audio_padding(_ws, 0), do: wait_for_audio(15_000)

  defp await_audio_padding(ws, pads_left) do
    case check_audio() do
      nil ->
        WebSockex.send_frame(ws, {:binary, @silence_frame})
        Process.sleep(100)
        await_audio_padding(ws, pads_left - 1)

      found ->
        found
    end
  end

  # Non-blocking peek. Non-audio events are consumed rather than requeued — nothing
  # after this point reads them, and leaving them would make the next drain/300 lie.
  defp check_audio do
    receive do
      {:grok_binary, _t, bin} -> {:binary, bin}
      {:grok, _t, %{"type" => "response.output_audio.delta", "delta" => b64}} -> {:json, b64}
      {:grok, _t, _} -> check_audio()
    after
      0 -> nil
    end
  end

  # ---- plumbing --------------------------------------------------------------

  defp say(ws, text) do
    send_json(ws, %{
      type: "conversation.item.create",
      item: %{type: "message", role: "user", content: [%{type: "input_text", text: text}]}
    })

    send_json(ws, %{type: "response.create"})
  end

  defp send_json(ws, map), do: WebSockex.send_frame(ws, {:text, Jason.encode!(map)})

  defp wait_for(types, timeout) do
    deadline = now() + timeout
    do_wait(types, deadline)
  end

  defp do_wait(types, deadline) do
    left = deadline - now()

    if left <= 0 do
      nil
    else
      receive do
        {:grok, _t, %{"type" => type} = msg} ->
          if type in types, do: msg, else: do_wait(types, deadline)

        {:grok_closed, reason} ->
          fail("connection", "closed: #{inspect(reason)}")
          nil
      after
        left -> nil
      end
    end
  end

  defp collect_audio(window, acc) do
    deadline = now() + window

    receive do
      {:grok, _t, %{"type" => "response.output_audio.delta", "delta" => b64}} ->
        collect_audio(deadline - now(), [Base.decode64!(b64) | acc])

      {:grok, _t, _} ->
        collect_audio(deadline - now(), acc)
    after
      max(window, 0) -> Enum.reverse(acc)
    end
  end

  defp drain(ms) do
    receive do
      _ -> drain(ms)
    after
      ms -> :ok
    end
  end

  defp persona_text do
    # Gemini takes a Content struct; flatten whatever Persona builds into text.
    case LiveCeci.Persona.system_instruction() do
      %{parts: parts} when is_list(parts) ->
        Enum.map_join(parts, " ", &Map.get(&1, :text, ""))

      %{"parts" => parts} when is_list(parts) ->
        Enum.map_join(parts, " ", &Map.get(&1, "text", ""))

      text when is_binary(text) ->
        text

      other ->
        inspect(other)
    end
  end

  defp env(name, default) do
    case System.get_env(name) do
      nil -> default
      "" -> default
      v -> v
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp ok(step, detail), do: record(:ok, "PASS", step, detail)
  defp fail(step, detail), do: record(:fail, "FAIL", step, detail)
  defp warn(step, detail), do: record(:warn, "????", step, detail)

  defp record(kind, tag, step, detail) do
    Process.put(:results, [{kind, step} | Process.get(:results, [])])
    IO.puts("#{tag}  #{String.pad_trailing(step, 34)} #{detail}")
  end

  defp summary do
    r = Process.get(:results, [])
    p = Enum.count(r, &(elem(&1, 0) == :ok))
    f = Enum.count(r, &(elem(&1, 0) == :fail))
    IO.puts("\n" <> String.duplicate("-", 62))
    IO.puts("#{p} passed, #{f} failed")

    if f == 0 do
      IO.puts("Grok can sit behind the same seam. Frontend unchanged: 16k up, 24k down.")
    else
      IO.puts("Failures above are what the adapter has to work around.")
    end
  end
end

GrokSpike.run()
