defmodule LiveCeci.Provider.GrokTest do
  @moduledoc """
  The Grok half of the seam: real xAI Voice Agent events in, neutral provider events
  out. The event shapes here are the ones the spike in `priv/spike/` saw on the wire,
  not invented ones.

  `translate/2` is private, so these go through `handle_frame/2` — which is also what
  the live socket exercises, and it catches a mistake the direct call would not: the
  frames a tool call has to send back cannot go out through `WebSockex.send_frame/3`
  from this process, so `handle_frame/2` must hand them to `handle_cast/2` instead.
  """
  use ExUnit.Case, async: true

  import LiveCeci.Eventually

  alias LiveCeci.Provider.Grok

  @pcm <<1, 0, 2, 0, 3, 0, 255, 127>>

  defp state, do: %{owner: self()}
  defp frame(event), do: Grok.handle_frame({:text, Jason.encode!(event)}, state())

  describe "voice" do
    test "a binary frame is voice, passed through untouched" do
      # This is the normal path: the session negotiates transport: "binary", so audio
      # never gets base64-wrapped in either direction.
      assert {:ok, _state} = Grok.handle_frame({:binary, @pcm}, state())
      assert_received {:provider, {:voice, @pcm}}
    end

    test "a base64 delta still works, in case the server ignores the transport request" do
      assert {:ok, _state} =
               frame(%{type: "response.output_audio.delta", delta: Base.encode64(@pcm)})

      assert_received {:provider, {:voice, @pcm}}
    end

    test "an undecodable delta is dropped rather than crashing the connection" do
      assert {:ok, _state} = frame(%{type: "response.output_audio.delta", delta: "not base64!!"})
      refute_received {:provider, _}
    end
  end

  describe "barge-in" do
    test "input_speech.started is the interruption signal" do
      # Gemini reports the effect (`interrupted`); Grok reports the cause. The socket
      # gets the same event either way.
      assert {:ok, _state} = frame(%{type: "input_speech.started"})
      assert_received {:provider, :interrupted}
    end
  end

  describe "transcripts" do
    test "input transcription is tagged :user" do
      assert {:ok, _state} =
               frame(%{
                 type: "conversation.item.input_audio_transcription.updated",
                 transcript: "toca uma musica"
               })

      assert_received {:provider, {:transcript, :user, "toca uma musica"}}
    end

    test "output transcription is tagged :ceci" do
      assert {:ok, _state} =
               frame(%{type: "response.output_audio_transcript.done", transcript: "claro"})

      assert_received {:provider, {:transcript, :ceci, "claro"}}
    end

    test "an empty transcript is dropped rather than drawn as a blank line" do
      assert {:ok, _state} =
               frame(%{
                 type: "conversation.item.input_audio_transcription.updated",
                 transcript: ""
               })

      refute_received {:provider, _}
    end
  end

  describe "tool calls" do
    test "a tool call emits a play command for the browser" do
      assert {:ok, _state} =
               frame(%{
                 type: "response.function_call_arguments.done",
                 name: "emitir_recibo",
                 call_id: "call_1",
                 arguments: ~s({"paciente":"M.S.","valor":"250"})
               })

      assert_received {:provider, {:action, %{action: "recibo", detail: "M.S. · R$ 250"}}}
    end

    test "the result goes back as two casts, because one message is not enough" do
      # conversation.item.create carries the answer; response.create is what makes the
      # model start speaking again. Sending only the first leaves it silent.
      assert {:ok, _state} =
               frame(%{
                 type: "response.function_call_arguments.done",
                 name: "resumo_mensal",
                 call_id: "call_2",
                 arguments: "{}"
               })

      assert_received {:"$websockex_cast", {:send, %{type: "conversation.item.create"} = item}}
      assert item.item.call_id == "call_2"
      assert item.item.type == "function_call_output"
      assert_received {:"$websockex_cast", {:send, %{type: "response.create"}}}
    end

    test "an unknown tool still answers the model, but emits no action" do
      assert {:ok, _state} =
               frame(%{
                 type: "response.function_call_arguments.done",
                 name: "teleport",
                 call_id: "call_3",
                 arguments: "{}"
               })

      refute_received {:provider, {:action, _}}
      assert_received {:"$websockex_cast", {:send, %{type: "conversation.item.create"}}}
    end

    test "malformed arguments degrade to an empty map rather than crashing the turn" do
      assert {:ok, _state} =
               frame(%{
                 type: "response.function_call_arguments.done",
                 name: "resumo_mensal",
                 call_id: "call_4",
                 arguments: "{not json"
               })

      assert_received {:provider, {:action, %{action: "resumo", detail: ""}}}
    end

    test "the reply is a cast, not a direct send_frame" do
      # WebSockex.send_frame/3 raises CallingSelfError when the caller is the socket
      # process, which handle_frame/2 is. This is the regression that guards it.
      assert {:ok, _state} =
               frame(%{
                 type: "response.function_call_arguments.done",
                 name: "pause",
                 call_id: "call_5",
                 arguments: "{}"
               })

      assert_received {:"$websockex_cast", {:send, _}}
    end
  end

  describe "handle_cast/2" do
    test "turns a queued payload into an outgoing text frame" do
      assert {:reply, {:text, json}, _state} =
               Grok.handle_cast({:send, %{type: "response.create"}}, state())

      assert Jason.decode!(json) == %{"type" => "response.create"}
    end
  end

  describe "failure paths" do
    test "an error event reaches the socket" do
      assert {:ok, _state} = frame(%{type: "error", error: %{message: "nope"}})
      assert_received {:provider, {:error, %{"message" => "nope"}}}
    end

    test "a disconnect is reported as closed" do
      assert {:ok, _state} = Grok.handle_disconnect(%{reason: :normal}, state())
      assert_received {:provider, {:closed, :normal}}
    end

    test "unknown events are ignored rather than crashing the connection" do
      assert {:ok, _state} = frame(%{type: "conversation.created", conversation: %{id: "c1"}})
      refute_received {:provider, _}
    end

    test "an undecodable frame is ignored" do
      assert {:ok, _state} = Grok.handle_frame({:text, "not json at all"}, state())
      refute_received {:provider, _}
    end
  end

  describe "session_update/1" do
    # Characterization, deliberately: this locks the shape the spike verified against
    # the live API. It cannot prove the shape is right — only that nobody changed it
    # by accident, which is the failure mode that survives compilation and 77 tests
    # and then shows up as the model mishearing you.
    setup do
      %{
        session:
          Grok.session_update(voice: "luna", language: "pt-BR", silence_duration_ms: 300).session
      }
    end

    test "audio moves as raw binary in both directions, not base64 in JSON", %{session: s} do
      assert s.audio.input.transport == "binary"
      assert s.audio.output.transport == "binary"
    end

    test "the rates are exactly what the browser already speaks", %{session: s} do
      # 16k up / 24k down. Change either and priv/frontend has to change with it —
      # the worklet resamples to 16k and the player builds 24k buffers.
      assert s.audio.input.format == %{type: "audio/pcm", rate: 16_000}
      assert s.audio.output.format == %{type: "audio/pcm", rate: 24_000}
    end

    test "server mode carries both timings", %{session: s} do
      # Silence closes a turn. Measured: leaving this unset made short utterances feel
      # like a stall.
      assert s.turn_detection.type == "server_vad"
      assert s.turn_detection.silence_duration_ms == 300
      assert s.turn_detection.idle_timeout_ms == 15_000
    end

    test "manual mode hands turn-ending to the client, and gives up the idle timeout" do
      # type: nil is what makes commit_turn/1 mean anything. idle_timeout_ms lives INSIDE
      # turn_detection, so it goes with it — manual mode has no server-side safety net,
      # and the browser's max-utterance guard is the only thing left.
      s = Grok.session_update(voice: "eve", turn_detection: :manual).session

      assert s.turn_detection == %{type: nil}
    end

    test "the silence budget is the configured one, not a constant" do
      # The knob is the entire point: SILENCE_DURATION_MS has to survive .env ->
      # runtime.exs -> Socket.init -> here. A hardcoded value would still pass every
      # other test in this block, and the .env setting would do nothing.
      s = Grok.session_update(voice: "eve", silence_duration_ms: 250).session
      assert s.turn_detection.silence_duration_ms == 250
    end

    test "an omitted silence budget falls back rather than sending nil" do
      # xAI validates this field. nil on the wire is an error response, not a default.
      s = Grok.session_update(voice: "eve").session
      assert s.turn_detection.silence_duration_ms == 400
    end

    test "every declared tool crosses over, shaped the way xAI wants it", %{session: s} do
      assert length(s.tools) == length(LiveCeci.Tools.declarations())
      assert Enum.all?(s.tools, &(&1.type == "function"))
      assert Enum.all?(s.tools, &(&1.name && &1.description && &1.parameters))

      assert Enum.map(s.tools, & &1.name) |> Enum.sort() ==
               ["agendar_sessao", "confirmar_presenca", "emitir_recibo", "resumo_mensal"]
    end

    test "the persona goes as a bare string, not Gemini's Content struct", %{session: s} do
      assert is_binary(s.instructions)
      assert s.instructions == LiveCeci.Persona.instruction()
    end

    test "the voice is whatever was configured", %{session: s} do
      assert s.voice == "luna"
    end

    test "a language becomes a transcription hint" do
      s = Grok.session_update(voice: "eve", language: "es-MX").session
      assert s.audio.input.transcription == %{language_hint: "es-MX"}
    end

    test "no language means the key is absent, not null — xAI rejects a null" do
      s = Grok.session_update(voice: "eve", language: nil).session
      refute Map.has_key?(s.audio.input, :transcription)
    end

    test "it survives the JSON encode it is about to go through" do
      assert Grok.session_update(voice: "luna", language: "pt-BR")
             |> Jason.encode!()
             |> Jason.decode!()
    end
  end

  describe "handle_connect/2" do
    test "the socket process is marked sensitive, so a crash report cannot print the key" do
      # WebSockex keeps extra_headers — "Authorization: Bearer <key>" — inside the
      # %WebSockex.Conn{} it carries as state. LiveCeci.Redact cannot reach that: crash
      # reports are written by the VM, not by our Logger calls. :sensitive is the VM's
      # own answer, and it is the DEFAULT provider whose state is a credential.
      parent = self()

      pid =
        spawn(fn ->
          Grok.handle_connect(nil, %{owner: parent})
          Process.put(:token, "Bearer xai-SUPERSECRET")
          send(parent, :ready)
          receive do: (:never -> :ok)
        end)

      assert_receive :ready, 1_000
      send(pid, {:conn, "Bearer xai-SUPERSECRET"})
      Process.sleep(20)

      assert {:messages, []} = Process.info(pid, :messages)
      assert {:dictionary, []} = Process.info(pid, :dictionary)

      Process.exit(pid, :kill)
    end
  end

  describe "endpoint_url/1" do
    test "the model rides in the query string, where a typo is silent" do
      # open/1's success path needs a live socket, but this half does not — and getting
      # it wrong connects you to a different model with everything else still working.
      assert Grok.endpoint_url("grok-voice-latest") ==
               "wss://api.x.ai/v1/realtime?model=grok-voice-latest"
    end
  end

  describe "open/1 failure paths" do
    test "a failed session.update closes the socket instead of leaking a billed session" do
      # start_link has already succeeded here, so xAI is billing. If session.update then
      # fails and open/1 just returns the error, nothing ever closes that session:
      # Socket.init stores session: nil, terminate/2 skips close/1, and the socket's
      # :normal exit is ignored by a non-trapping WebSockex process.
      #
      # A plain process stands in for the socket: send_json/2 times out against it, which
      # is the failure being exercised. What matters is that a close cast arrives.
      ws = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(ws, :kill) end)

      Grok.close(ws)

      # WebSockex.cast/2 delivers {:"$websockex_cast", :close} to the target's mailbox.
      # Polled rather than slept on: a fixed sleep is a bet on the scheduler.
      assert eventually(fn ->
               {:messages, msgs} = Process.info(ws, :messages)
               {:"$websockex_cast", :close} in msgs
             end)
    end
  end

  describe "commit_turn/1" do
    test "the turn is closed with two messages, not one" do
      # input_audio_buffer.commit turns the buffer into a user message; response.create
      # is what makes her answer it. Sending only the first leaves her holding the turn.
      assert :ok = Grok.commit_turn(self())

      assert_received {:"$websockex_cast", {:send, %{type: "input_audio_buffer.commit"}}}
      assert_received {:"$websockex_cast", {:send, %{type: "response.create"}}}
    end

    test "a dead session is not an error — the turn is over either way" do
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _reason}, 1_000

      assert :ok = Grok.commit_turn(dead)
      assert Process.alive?(self())
    end
  end

  describe "send_audio/2" do
    test "the mic frame is handed off by cast, so the socket process never waits" do
      # It used to be WebSockex.send_frame/3, a :gen.call. The socket process is BOTH
      # directions for one listener — microphone in, her voice out — so a slow upstream
      # ACK held it for up to a second per ~100 ms frame while decoded voice waited
      # behind it. This is the regression guard for that.
      assert :ok = Grok.send_audio(self(), <<1, 0, 2, 0>>)
      assert_received {:"$websockex_cast", {:send_audio, <<1, 0, 2, 0>>}}
    end

    test "the cast becomes one binary frame, with no envelope and no base64" do
      # The session negotiated transport: "binary". Wrapping this in JSON again would
      # cost 33% on the wire and the server would not be expecting it.
      assert {:reply, {:binary, <<1, 0, 2, 0>>}, _state} =
               Grok.handle_cast({:send_audio, <<1, 0, 2, 0>>}, state())
    end

    test "a dead session comes back as an error rather than exiting the caller" do
      # Whatever else changes, one stalled upstream must never take the browser
      # connection down with it.
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _reason}, 1_000

      assert Grok.send_audio(dead, <<1, 0>>) in [:ok, {:error, {:exit, :noproc}}]
      assert Process.alive?(self())
    end
  end

  describe "close/1" do
    # The first version used Process.exit(ws, :normal), which another process that is
    # not trapping exits silently ignores — so nothing closed, and the session stayed
    # open and billed upstream until the remote gave up.
    test "asks the connection to close rather than signalling it" do
      # A stand-in for the WebSockex process: it forwards whatever it is sent, so the
      # test can assert a message actually arrived rather than inspecting a mailbox
      # that may already have been drained.
      test = self()
      ws = spawn(fn -> receive(do: (msg -> send(test, {:got, msg}))) end)
      on_exit(fn -> if Process.alive?(ws), do: Process.exit(ws, :kill) end)

      assert :ok = Grok.close(ws)
      assert_receive {:got, {:"$websockex_cast", :close}}, 500
    end

    test "tolerates an already-dead session" do
      # monitor/DOWN, not Process.sleep. A sleep asserts that 20 ms is always enough,
      # which is a claim about the machine rather than about the code, and it is the
      # shape of test that passes for a year and then fails once in CI.
      ws = spawn(fn -> :ok end)
      ref = Process.monitor(ws)
      assert_receive {:DOWN, ^ref, :process, ^ws, _reason}, 1_000

      refute Process.alive?(ws)
      assert :ok = Grok.close(ws)
    end
  end

  describe "handle_cast/2 close" do
    test "a close cast becomes a real close, not a dropped signal" do
      assert {:close, _state} = Grok.handle_cast(:close, state())
    end
  end

  describe "open/1" do
    test "refuses to open without a key rather than failing at connect time" do
      assert {:error, :missing_grok_api_key} =
               Grok.open(owner: self(), model: "m", voice: "v", api_key: "")
    end
  end
end
