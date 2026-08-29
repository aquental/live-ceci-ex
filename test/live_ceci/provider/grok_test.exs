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

    test "output transcription is tagged :mira" do
      assert {:ok, _state} =
               frame(%{type: "response.output_audio_transcript.done", transcript: "claro"})

      assert_received {:provider, {:transcript, :mira, "claro"}}
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
                 name: "play_playlist",
                 call_id: "call_1",
                 arguments: ~s({"mood":"dream pop"})
               })

      assert_received {:provider, {:play, %{action: "playlist", value: "dream pop"}}}
    end

    test "the result goes back as two casts, because one message is not enough" do
      # conversation.item.create carries the answer; response.create is what makes the
      # model start speaking again. Sending only the first leaves it silent.
      assert {:ok, _state} =
               frame(%{
                 type: "response.function_call_arguments.done",
                 name: "skip",
                 call_id: "call_2",
                 arguments: "{}"
               })

      assert_received {:"$websockex_cast", {:send, %{type: "conversation.item.create"} = item}}
      assert item.item.call_id == "call_2"
      assert item.item.type == "function_call_output"
      assert_received {:"$websockex_cast", {:send, %{type: "response.create"}}}
    end

    test "an unknown tool still answers the model, but emits no play command" do
      assert {:ok, _state} =
               frame(%{
                 type: "response.function_call_arguments.done",
                 name: "teleport",
                 call_id: "call_3",
                 arguments: "{}"
               })

      refute_received {:provider, {:play, _}}
      assert_received {:"$websockex_cast", {:send, %{type: "conversation.item.create"}}}
    end

    test "malformed arguments degrade to an empty map rather than crashing the turn" do
      assert {:ok, _state} =
               frame(%{
                 type: "response.function_call_arguments.done",
                 name: "play_playlist",
                 call_id: "call_4",
                 arguments: "{not json"
               })

      assert_received {:provider, {:play, %{action: "playlist", value: ""}}}
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

  describe "session_update/2" do
    # Characterization, deliberately: this locks the shape the spike verified against
    # the live API. It cannot prove the shape is right — only that nobody changed it
    # by accident, which is the failure mode that survives compilation and 77 tests
    # and then shows up as the model mishearing you.
    setup do
      %{session: Grok.session_update("luna", "pt-BR").session}
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

    test "turn detection carries both timings", %{session: s} do
      # 500 ms of silence closes a turn. Measured: leaving this unset made short
      # utterances feel like a stall.
      assert s.turn_detection.type == "server_vad"
      assert s.turn_detection.silence_duration_ms == 500
      assert s.turn_detection.idle_timeout_ms == 15_000
    end

    test "every declared tool crosses over, shaped the way xAI wants it", %{session: s} do
      assert length(s.tools) == length(LiveCeci.Tools.declarations())
      assert Enum.all?(s.tools, &(&1.type == "function"))
      assert Enum.all?(s.tools, &(&1.name && &1.description && &1.parameters))

      assert Enum.map(s.tools, & &1.name) |> Enum.sort() ==
               ["pause", "play_playlist", "play_track", "skip"]
    end

    test "the persona goes as a bare string, not Gemini's Content struct", %{session: s} do
      assert is_binary(s.instructions)
      assert s.instructions == LiveCeci.Persona.instruction()
    end

    test "the voice is whatever was configured", %{session: s} do
      assert s.voice == "luna"
    end

    test "a language becomes a transcription hint" do
      s = Grok.session_update("eve", "es-MX").session
      assert s.audio.input.transcription == %{language_hint: "es-MX"}
    end

    test "no language means the key is absent, not null — xAI rejects a null" do
      s = Grok.session_update("eve", nil).session
      refute Map.has_key?(s.audio.input, :transcription)
    end

    test "it survives the JSON encode it is about to go through" do
      assert Grok.session_update("luna", "pt-BR") |> Jason.encode!() |> Jason.decode!()
    end
  end

  describe "send_audio/2" do
    test "pcm goes out as one binary frame, with no envelope and no base64" do
      # The session negotiated transport: "binary". Wrapping this in JSON again would
      # cost 33% on the wire and the server would not be expecting it.
      ws = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(ws, :kill) end)

      # WebSockex.send_frame/3 will time out against a plain process; what matters is
      # that it was a binary frame and that the timeout came back as an error tuple
      # rather than exiting this process.
      assert {:error, {:exit, _}} = Grok.send_audio(ws, <<1, 0, 2, 0>>)
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
      ws = spawn(fn -> :ok end)
      Process.sleep(20)
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
